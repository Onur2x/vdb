# VDB v3 — Uygulama Geliştirme Kılavuzu

Bu doküman, **v3 motoru üzerinde uygulama yazacak** geliştirici içindir.
Motorun içini (sayfa, WAL, heap) bilmeniz gerekmez; burada yalnızca
uygulamanın dokunacağı yüzey ve ölçülmüş davranışlar var.

> Durum: **v3.1 sabit**. Bundan sonra motor değişiklikleri yalnız hata
> düzeltmesi olarak yapılır; yeni özellikler v3.2'ye gider (bkz. §9).

---

## 1. Tek kural: giriş noktası `VDbFactory`

Uygulama motorun somut tipini (`TVDb`) **tanımaz**. Açılış tek yerden yapılır:

```pascal
uses VDbBackendApi, VDbFactory, VDbTable, VDbSql;

var
  Be: IVdbBackend;
begin
  VdbOpenOrCreate('C:\uygulama\veri\veritabani.odb', Be);
  ...
  Be := nil;   // motoru kapatır, dosya kilidini bırakır
end;
```

| Çağrı | Davranış |
|---|---|
| `VdbOpenOrCreate(Path, Be)` | yoksa **v3** oluşturur, varsa açar |
| `VdbOpen(Path, Be)` | varsayılan `CreateIfMissing=True`; v2 dosyasını **reddeder** |
| `VdbOpen(Path, Be, False)` | dosya yoksa hata (`EVdbFactory`) |
| `VdbOpenWithPassword(Path, Parola, Be)` | şifreli v3 açar/oluşturur |
| `VdbOpen(Path, Be, True, True)` | yalnız göç araçları: v2'ye izin verir |

**Yapmayın:** `TVDb.Create`, `TVSql.Create('dosya.odb')` (v2 kısayolu),
`TVDbCore` / `TVDbWal` kullanımı. Bunlar v2 okuma yolu içindir ve v3
dosyasını açmaz.

### Neden `out` parametre

FPC 3.2.4'te arayüz **döndüren** fonksiyon (`function ...: IVdbBackend`)
sonuca fazladan bir referans bırakıyor; `Be := nil` motoru kapatmıyor ve
aynı süreçte dosya yeniden açılamıyor ("dosya kullanımda"). Bu yüzden
giriş noktaları `out Be` kullanır. Ölçüm: `tmp64/probe5`, `probe6`.

---

## 2. Standart iskelet

Açılış → şema → iş → kapanış. Kapanış sırası **önemlidir**: önce SQL,
sonra tablo katmanı, en son motor.

```pascal
program uygulama;

{$mode delphi}{$H+}

uses
  SysUtils, VDbBackendApi, VDbFactory, VDbTable, VDbSql, VDbErr;

var
  Be: IVdbBackend;
  Tb: TVTableDb;
  Sq: TVSql;
  R: TSqlResult;

  procedure Ac;
  begin
    VdbOpenOrCreate('veri\veritabani.odb', Be);
    Tb := TVTableDb.CreateBackend(Be);
    Sq := TVSql.Create(Tb);
    Tb.Open('veri');           // şemayı yükler (dosya adı değil, DİZİN)
    Sq.AutoTransaction := True; // tek cümle = tek işlem (autocommit)
  end;

  procedure Kapat;
  begin
    Sq.Free;
    Tb.Free;                   // motor referansını da bırakır
    Be := nil;                 // dosya kilidi burada açılır
  end;

begin
  Ac;
  try
    R := Sq.Exec('CREATE TABLE IF NOT EXISTS kisi (id INTEGER PRIMARY KEY, ad TEXT)');
    R := Sq.Exec('INSERT INTO kisi (ad) VALUES (''Ayşe'')');
    R := Sq.Exec('SELECT id, ad FROM kisi');
    WriteLn(R.Msg, ' / ', Length(R.Rows), ' satır');
  finally
    Kapat;
  end;
end;
```

`Tb.Open` parametresi **dizin**tir (v2 uyumu için). Yeni kodda
`ExtractFileDir(Be.FilePath)` kullanın:

```pascal
Tb.Open(ExtractFileDir(Be.FilePath));
```

`R` alanları: `Fields` (kolon adları), `Rows` (string matris),
`Affected`, `Msg`, `Stmts`. **`Ok` alanı yoktur**; hata `EVDbException`
fırlatır (`E.ErrorCode`).

---

## 3. Sorgu ve yazma

```pascal
// Parametreli (injection'a karşı tercih edin)
R := Sq.Exec('SELECT id, ad FROM kisi WHERE ad = ?', ['Ayşe']);

// Toplu yazma: tek işlemde çok satır (ölçülen en hızlı yol)
Sq.Exec('BEGIN');
try
  for i := 1 to 100000 do
    Sq.Exec('INSERT INTO log (id, mesaj) VALUES (?, ?)', [i, 'kayıt ' + IntToStr(i)]);
  Sq.Exec('COMMIT');
except
  Sq.Exec('ROLLBACK');
  raise;
end;
```

Toplu yazmada `Tb.BeginBatch` / `CommitBatch` daha da az ek yük üretir
(DDL de geri alınabilir olur); ancak `Tb` seviyesindeki bu API, SQL
katmanını atladığınız anlamına gelir — uygulama kodunda `Sq.Exec` yeterli.

---

## 4. Kalıcılık (dayanıklılık) ayarı

v3'te WAL **her zaman açıktır**; commit önce `.wal`'e yazılır, çökme
sonrası açılışta replay ile kurtarılır. `Commit(True)` = fsync.

| Yol | Ölçülen maliyet (bu makine) |
|---|---|
| autocommit tek satır (fsync'li) | **0,449 ms/satır** |
| commit başına WAL hacmi | **8.252 B** (yalnız değişen sayfalar) |
| commit-fsync | **0,422 ms** |
| toplu INSERT (tek işlem) | **5,79 µs/satır** |
| PK nokta araması | **5,13 µs** |
| `COUNT(*)` | **0,0–0,1 ms** (canlı sayaç) |

Uygulama açısından kural: **çok satır yazıyorsanız tek işlemde yazın.**
Tek tek autocommit, satır başına bir fsync demektir.

---

## 5. Bakım komutları (uygulamadan çağrılabilir)

| Komut | Ne yapar |
|---|---|
| `VERIFY` | sayfa CRC + heap zinciri + anahtar sayısı denetimi; `Msg`'de rapor |
| `BACKUP TO 'yol.odb'` | checkpoint sonrası tutarlı tam kopya |
| `VACUUM` | canlı kayıtları yeni dosyaya taşır, atomik değişim |
| `ANALYZE [tablo]` | planlayıcı istatistikleri |
| `SHOW STATS` | v3 metrikleri (bkz. §6) |
| `REINDEX` | indeksleri yeniden kurar |

Öneri: uygulama kapanışında veya günlük bakımda `VERIFY` + `BACKUP TO`;
`VACUUM`'ı yalnız çok silme sonrası, kullanıcı tetiklemesiyle çalıştırın
(büyük dosyada uzun sürer ve geçici olarak iki kat alan ister).

Arayüzden de erişilebilir:

```pascal
if Be.Verify(rep) then ...;      // Boolean + rapor
Be.BackupTo('yedek\2026-10-25.odb');
Be.Compact(oldB, newB);          // VACUUM'un programatik karşılığı
```

### 5.1 Kısmi geri alma (v3.2)

`SAVEPOINT` artık v3'te de v2 ile aynı semantikle çalışır:

```pascal
Be.Savepoint('adim1');
try
  Sq.Exec('UPDATE hesap SET bakiye = bakiye - 100 WHERE id = 1');
  Sq.Exec('UPDATE hesap SET bakiye = bakiye + 100 WHERE id = 2');
except
  Be.RollbackToSavepoint('adim1');   // hedef savepoint KALIR
  raise;
end;
Be.ReleaseSavepoint('adim1');        // commit ETMEZ
```

- Aynı isimle ikinci `SAVEPOINT` reddedilir (`ecDuplicateSavepoint`).
- `COMMIT`/`ROLLBACK` bütün savepoint'leri düşürür.
- `SAVEPOINT` açık işlem yoksa örtük işlem açar.

### 5.2 Otomatik sıkıştırma (v3.2)

v2'deki yönetim ayarları artık `IVdbBackend` sözleşmesinde; **varsayılan
KAPALI**:

```pascal
Be.AutoCompactEnabled := True;        // açıkça istiyorsanız
Be.AutoCompactRatio := 0.35;          // ölü alan / dosya oranı eşiği
Be.AutoCompactMinBytes := 4 * 1024 * 1024;
WriteLn(Be.DeadBytes, ' / ', Be.DataFileSize,
        ' sikistirma=', Be.AutoCompactCount,
        ' hata=', Be.LastAutoCompactError);
```

Karar her commit'ten sonra O(1)'dir; yalnız eşik aşılırsa dosya bir kez
baştan yazılır. Sıkıştırma hatası commit'i **bozmaz** (veri zaten
fsync'li); hata `LastAutoCompactError`'a yazılır.

### 5.3 Ham anahtar-değer yüzeyi (v3.2)

Motorun somut tipini bilmeden `IVDbKvStore`:

```pascal
var St: IVDbKvStore;
St := TVdbBackendKvStore.Create(Be);   // Be: IVdbBackend
St.Put(1, VDbStrToBytes('deger'));
```

---

## 6. `SHOW STATS` (v3 sütunları)

```
engine | commands | total_us | max_us | avg_us | tables | tables_analyzed
batch_active | live_keys | data_file_bytes | wal_file_bytes | idx_file_bytes
```

v2'deki okuma önbelleği sayaçları (`cache_hits` vb.) v3'te yoktur; yerine
gerçek dosya boyutları verilir. `SHOW STATS TABLE t` (ANALYZE sonrası)
aynı biçimde çalışır.

Prometheus için aynı metrikler `Sq.GetMetricsText` ile alınır; v3'te
`vdb_engine_info{engine="v3"}`, `vdb_live_keys`, `vdb_wal_file_bytes`,
`vdb_idx_file_bytes` satırları bulunur (v2'ye özgü `vdb_read_cache_*`
satırları v3'te yoktur).

---

## 7. Şifreleme

Şifreleme **dosya düzeyindedir** (sayfa başına AES-256-GCM). Parola
açılışta verilir:

```pascal
VdbOpenWithPassword('veri\gizli.odb', 'parola', Be);
```

- Parola yoksa/yanlışsa açılış **reddedilir** (sessiz boş veritabanı yok).
- v2'nin kayıt/kolon düzeyi şifrelemesi v3'te yoktur; sayfa şifreleme
  tüm veriyi kapsar.
- Parolayı koda gömmeyin; kullanıcıdan alın veya işletim sistemi
  kasasından okuyun.

---

## 8. Eşzamanlılık ve dosya düzeni

- Aynı dosyaya **birden çok süreç** bağlanabilir (v3.16). Kilit oturum boyu
  değil **işlem kapsamlıdır**: okuma paylaşımlı kilitle, yazma commit
  penceresinde tam kilitle yürür. Yazarlar **paraleldir**, commit'ler
  sıralıdır (v3.18 iyimser mod, bkz. §9).
- Kilit `ABusyMs` boyunca alınamazsa ham "paylaşım ihlali" değil, açık bir
  hata verilir: `veritabani dosyasi kullanimda (baska islem acik): ...`.
  Varsayılan `ABusyMs = 0` (beklemeden dener).
- Aynı süreçte yeniden açmak için önce `Be := nil` (veya `Tb.Free`).
- Dosyanın yanında türetilmiş dosyalar oluşur:

```
veritabani.odb         asıl veri
veritabani.odb.wal     işlem günlüğü (commit sırasında; checkpoint'te kısalır)
veritabani.odb.idx     açılış hızlandırma önbelleği (silinebilir, yeniden üretilir)
veritabani.colkey      kolon anahtarı (yalnız kolon şifrelemesi kullanılırsa)
```

- Yedek alırken **`.odb`'yi kopyalamak yeterlidir** (`BACKUP TO` bunu
  tutarlı biçimde yapar). `.wal`/`.idx` yedeklemeyin; `.idx` zaten
  yeniden üretilir.

---

## 9. Bugünkü sınırlar (v3.18)

| Özellik | Durum | Not |
|---|---|---|
| `AS OF SEQUENCE n` | **var** (v3.2) | WAL penceresindeki n'inci commit'in tam görüntüsü geçici kopyada kurulur; yalnız son checkpoint'ten beri. n = commit sayısı |
| PITR (`RECOVER TO`), WAL arşivi, `AS OF TIMESTAMP/VERSION` | **var** (v4) | Mantıksal değişim günlüğü (`<db>.log`): `AS OF TIMESTAMP/VERSION`, `ARCHIVE WAL SET DIR=`, `RECOVER TO`. Günlük **varsayılan olarak budanmaz**. v3.8'den itibaren isteğe bağlı budama: `LogPruneEnabled` + `LogPruneKeepDays` (varsayılan 30) + `LogPruneKeepBases` (varsayılan 2); checkpoint sonrası otomatik veya elle `LogPrune` |
| Replication (`START REPLICATION` vb.) | **var** (v4) | Mantıksal grup taşıma; **dosya tabanlı** (paylaşımlı dizin). TCP ile replikasyon açıkça reddedilir |
| Zone map / bölüm budama | **var** (v3.3) | Sayfa düzeyi; kazanç **seçici** yüklemlerde. Orta seçicilikte ölçülebilir kazanç yok. v3.9: `=` ve `IN` listelerinde **negatif sabitler** de daraltır (`k IN (-1,-2)`); bölüm numarası hesaplanamazsa koşul katkı vermez (satır kaybı yok) |
| MVCC (süreç içi çok oturum) | **var** (v3.4) | READ COMMITTED; her oturum kendi yazma kümesinde yazar, **ilk commit kazanır**, kaybeden `yazma cakismasi` ile durur. DDL/`SAVEPOINT`/`DEFERRABLE` çoklu yazmada reddedilir. Snapshot isolation yok |
| MVCC (süreçler arası) | **var** (v3.16) | Aynı `.odb` dosyasına birden çok süreç bağlanır; işlemler **paralel** açılır, commit'ler sıralıdır. Kilit **işlem kapsamlı**: motor kapısının 0→1 geçişinde paylaşımlı kilit (`AcquireRead`), 1→0'da bırakılır; yazma girişi paylaşımlıyı bırakıp tam kilidi alır (`AcquireWrite`). Önbellek tazeliği `<db>.gen` 8 baytlık değişiklik sayacıyla denetlenir (meta sayfaya LSN yazmak taban dosyanın tutarlılığını bozduğu için ayrı dosya). Değişen sayaçta `DropCache` + WAL görünümü tazelenir. Güvenlik ağı: paylaşımlı kilit altında yazma ilkeli çağrılırsa kilit kendiliğinden yükselir. **Yazarlar paraleldir, commit'ler sıralıdır** (v3.18 iyimser mod). Açık bir yazma işlemi veri dosyasının tam kilidini **tutmaz**, yalnız `.gen` üzerinde **rezervasyon** tutar; tam kilit yalnız commit penceresinde alınır. Rezervasyon `BeginBatch`'te **beklemeden** denenir (`TryAcquireWriteHold`): alınırsa seri yol aynen çalışır; alınamazsa işlem **iyimser modda** açılır — yazımlar bellekte birikir, görüntü sabitlenir (`BeginDeferRefresh`) ve anahtar başına before-image toplanır. Commit anında rezervasyon `ABusyMs` boyunca beklenir, motor tazelenir ve **anahtar bazında** çakışma denetimi yapılır: **aynı anahtara** iki süreç yazdıysa ikinci commit `yazma cakismasi` hatasıyla **açıkça durur** (veri kaybı yok), **farklı anahtarlar** ise iki süreç de commit eder. Bu yüzden **uzun işlem okuyucuları bekletmez** (v3.18'de ölçüldü: açık işlem altında 20 okuma, en yüksek **0 ms**) ve ikinci yazarın işlem açışı da beklemez (ölçüldü: **0 ms**, eşik 300 ms). Çakışma yönetimi **anahtar** düzeyindedir; sayfa düzeyinde paralel commit kapsam dışıdır. `ABusyMs` varsayılanı **0**. v3.18: **açık salt-okunur oturum yazarları bloklamaz** — RO kilit de ifade kapsamlıdır, `<db>.gen` değişince RO WAL imajları bellek içinde tazelenir (`ResetReadOnlyImages` + `Recover(ApplyReadOnly)` + `FHeap.Open`, diske yazma yok). **Bedel: RO oturumda tekrarlanabilir okuma yoktur**, her ifade güncel durumu görür. Ölçülen maliyet: işlem başına 8,8 µs (okuma) / 15,5 µs (yazma), parti içi `Put` 2,215 µs/satır (regresyon yok). `lockchk` 36/36 (tazelik + uzun işlem + paralel yazar dahil), `prochk` 15/15 (şifreli dahil), satır kaybı yok |
| Toplu INSERT hızı | v2'nin **~1,5 katı** yavaş | v3 5,77 / v2 3,82 µs satır (200k×3 kolon, commit dâhil; aynı sonda, 3 koşu medyanı). v3.10: 6,63 → 6,12 µs (günlük kodlaması yerinde, etiket farkı ara sözlüksüz, `Put` tek arama). v3.11: **5,77 µs** (eşleşmiş ölçüm 6,16 → 5,77 = −%6,3; satır gövdesi varint, daha az bayt). Kalan fark: satır başına 4 kez çözülen oturum kümesi + WAL commit/günlük bedeli |
| Snapshot isolation (v3.15) | **var** | Açık işlemi olan oturum `BeginBatch` anındaki görüntüyü okur: başka oturumun sonraki commit'leri görünmez, silinen satır geri gelir, eklenen satır görünmez, `COUNT`/tarama tutarlı. Kendi yazıları öncelikli; commit sonrası yeni okuma güncel veriyi görür. Yazma yolu değişmedi (**ilk commit kazanır**), bayat görüntüye dayanan yazma çakışmayı yalnız ilk yazmadan sonraki commit'te yakalar (klasik lost-update). Bellek: değişen satırların post-image penceresi en uzun açık işlem boyunca; `FUndo` tüm işlemler kapanınca temizlenir. Yalnız **tek süreç içinde** çalışır; süreçler arasında görünürlük "son commit" düzeyindedir (v3.18 yazarlar paralel, commit'ler sıralı; snapshot süreçler arasında taşınmaz). Temiz snapshot'ta ölçülebilir okuma maliyeti yok (±%2) |
| İfade değerlendirme (v3.14) | **var** | Ağaç yorumlayıcı (`EvalExpr`) tüm ifadeleri destekler. INT kolon/tam sayı literali `+ - *` (ve tekli `-`) zincirleri için **tip-duyarlı tam sayı yolu**: Int64'te yürür, ara düğümde metin üretmez; uygun olmayan her durumda ağaç yolu aynen çalışır (birebir eşdeğerlik diferansiyel kanıtlı). String tutan yığın **bytecode ölçümle reddedildi** (ağaç 0,80 → bytecode 1,07 µs/satır, +%34; maliyet ara metin üretiminde). Ölçülen: zincirlerde −%26…%39, ifadeli `COUNT` −%15, ifade içermeyen sorgular nötr |
| Satır gövdesi / dosya biçimi (v3.13) | **var** | Satır gövdesi: `$FFFF` işareti + varint kolon sayısı + kolon başına `ctype` + varint uzunluk (`0` = NULL). PK **satır gövdesinde ikinci kez yazılmaz**: `varint pkLen = 0` ise hemen `varint v` gelir (`0` = boş PK, `v ≥ 1` → PK `v-1`. kolonun değeri); `pkLen > 0` eski satır içi biçim. **Dosya sürümü 5**; sürüm 3 ve 4 dosyalar açılır (aynı dosyada eski/yeni satır bir arada), ilk yazılabilir açılışta başlık 5'e yükseltilir; salt-okunur açılış yazmaz. Eski ikili sürüm 5'i açık hatayla reddeder. Ölçülen: satır −%13…%29 (küçük INT PK 21,8 → 19,0 B; büyük INT PK 30,7 → 21,9 B; TEXT PK 36,0 → 27,0 B), kapanmış `.odb` −%9,9…%12,8 (aynı veri, iki ikili). Okuma bedeli: `SUM(a)` 0,31 → 0,40 µs/satır (pk artık kolondan çözülüyor), metin taraması değişmedi (2,80 → 2,83 µs/satır) |
| JOIN yöntemi (v3.12) | **hash + indeks** | İndekssiz eşitlik join'i hash join (10k×10k, 0 satır sonuç: 42 ms). ON'da eşitlik **+ ek koşul** da hash yolunu kullanır; ek koşullar eşleşen çiftlerde `JoinOnOk` ile uygulanır. Merge JOIN yok — ölçümle gereksiz (sıralı girdi yok). Sonuç satırı kopyalama ~3,2 µs/satır (1M satır 3,2 s); ON/WHERE yüklemi join'e itilmez (ölçülmüş sonraki fırsat) |
| `ScanAll` hızı (v3.9) | iyileşti | 200k satır + **açık yazma kümesi**: 45,00 → **32,00 ms** (son üç koşu 31–32 ms, aynı makine/sonda). Satır başına 3 kilit alma kaldırıldı: yazma kümesi tarama başında bir kez çözülür |
| Motor kilidi (v3.9) | `TVdbGate` | Her iş parçacığı tuttuğu kilitlerin `threadvar` yığınını taşır; **iç içe giriş kritik bölüme hiç girmez** (yeniden giriş varsayımı kalktı), paylaşılan alanlar kilit dışında okunmaz. `Leave` sahipsiz çıkışta açık hata verir. `ScanAllAt` / PITR taraması paylaşılan `FScan*` tamponunu artık kilit altında kullanır (eşzamanlı `ScanAll` ile bozulma giderildi) |
| SQLite yazımları (v3.7) | **var** | `BEGIN [TRANSACTION|WORK] [IMMEDIATE|DEFERRED|EXCLUSIVE]`, `CREATE INDEX IF NOT EXISTS`, `INSERT OR REPLACE/IGNORE/ABORT/FAIL/ROLLBACK`, `CREATE TEMP[ORARY] TABLE`, `CREATE TABLE ... AS SELECT`, `UPDATE ... SET ... FROM`, `WITH x AS (INSERT/UPDATE/DELETE ...)`, `AS`'siz `CREATE TRIGGER` |
| `TEMP` tablo ömrü | sınır | Kabul edilir ama tablo **kalıcıdır**: oturum kapanınca silinmez (gerçek geçici tablo altyapısı yok) |
| `UPDATE ... FROM` kapsamı | sınır | Tek kaynak (tablo veya parantezli SELECT) + alias; `FROM` içinde **JOIN reddedilir**. Çoklu eşleşmede ilk kaynak satırı kullanılır (SQLite da tek satır seçer) |
| `INSERT OR FAIL/ROLLBACK` | sınır | Çakışmada hata verir; `ROLLBACK`'ın "tüm işlemi geri al" ayrımı uygulanmaz (varsayılan ABORT davranışı) |
| `INSERT OR ...` + `ON CONFLICT` | sınır | Aynı cümlede birlikte reddedilir (açık hata) |
| Günlük budama (v3.8) | **var**, varsayılan KAPALI | Segment düzeyinde **önek** silme: yalnız baştan kesintisiz tam segmentler. Aktif (son) segment, en yeni taban ve sonrası her zaman korunur. Hiç taban yoksa hiçbir şey silinmez |
| Budama kesim noktası | politika | "30 gün VEYA 2 taban imajı — hangisi daha uzun geçmiş tutuyorsa". Zaman kuralı `LogPruneKeepDays=0` ile kapatılır (yalnız taban kuralı). |
| Budama sonrası PITR | sınır | Kalan en eski tabandan **önceki** bir ana `AS OF`/`RECOVER TO` hedefi artık kurulamaz; açık hata döner (sessiz yanlış sonuç yok) |
| Budama maliyeti | sınır | Süresi dolmuş önek varsa checkpoint **yeni bir taban imajı** yazar (tam dosya kopyası). Sonra önek silinir; pencere dolunca tekrarlanır. Segment içi yeniden yazma yok |

Aynı açık veritabanında **oturum yalitimi** vardır: `VDbSetTxnSession`
(v2) / `VdbBackendSessionId` ile kimliği olan iki oturum birbirinin **commit
edilmemiş** yazısını görmez. v3.4'ten itibaren ikinci oturum da **yazabilir**;
aynı anahtarı iki oturum yazarsa ilk commit uygulanır, ikincisi
`yazma cakismasi: … (islem geri alindi)` ile durur (kayıp güncelleme yok).
v2'de kural eskisi gibi tek yazıcıdır (ikinci oturum yazamaz).

v3.2'de **çözülenler**: `SAVEPOINT`/`ROLLBACK TO` (§5.1),
`ALTER DATABASE KEY`, kolon şifreleme (`.colkey`), `IVdbBackend` üzerinde
yönetim/ölçüm API'si ve otomatik sıkıştırma (§5.2), `TVdbBackendKvStore`
(§5.3), `VDbSqlServer`'ın v3 motoruyla çalışması.

v3.7'de **çözülenler**: SQLite uygulamalarının değiştirilmeden çalışması için
eksik yazımlar (`BEGIN` varyantları, `CREATE INDEX IF NOT EXISTS`,
`INSERT OR ...`, `CREATE TEMP TABLE`, CTAS, `UPDATE ... FROM`,
`WITH x AS (DML)`, `AS`'siz trigger). Ayrıntı ve ölçülen kapı sayıları:
`V3_YOL_HARITASI.md` §v3.7.

v3.9'da **çözülenler** (kalan üç motor notu): negatif sabitlerle bölüm
budama; kilit yeniden girişliliğinin varsayım olmaktan çıkması
(`TVdbGate` — sahip + derinlik); taramada satır başına 3 kilit almanın
kaldırılması (200k satır: 45,00 → 32,00 ms). Ayrıca `ScanAllAt`/PITR
taramasının paylaşılan tamponu kilitsiz kullanması (eşzamanlı `ScanAll`
ile sonuç bozulması) düzeltildi. Ayrıntı: `V3_YOL_HARITASI.md` §v3.9.

v3.10'da **çözülenler**: toplu INSERT'in v2 karşısındaki hız gerilemesi
kısmen kapatıldı — 6,63 → **6,12 µs/satır** (%7,8). Düzeltmeler yazma
yolundadır, **dosya biçimi değişmez**: değişim günlüğü kaydı doğrudan grup
tamponuna yazılır (satır başına 2 ayırma + 3 kopya kalktı), etiket farkı ara
sözlük yerine doğrudan sayaca işlenir, `Put` anahtar başına tek sözlük
araması yapar. v3 hâlâ v2'nin ~1,6 katı yavaştır; kalan farkın büyük kısmı
satır başına 4 kez çözülen oturum kümesi ile WAL/günlük dayanıklılık
bedelidir. Ayrıntı ve ölçümler: `V3_YOL_HARITASI.md` §v3.10.

v3.11'de **çözülenler**: satır gövdesi varint kodlaması (ertelenen listenin
ilk maddesi) — dosya **−%15,7** (200k×3 kolon), toplu INSERT 6,16 → **5,77
µs/satır** (−%6,3), tarama hızı değişmedi. Biçim değiştiği için **dosya
sürümü 4** oldu: sürüm 3 dosyalar okunur ve ilk yazılabilir açılışta
yükseltilir; eski ikili sürüm 4'ü açık hatayla reddeder (sessiz yanlış
sonuç yok). Ayrıntı ve geriye dönük okuma kanıtı: `V3_YOL_HARITASI.md`
§v3.11.

v3.12'de **çözülenler**: `ON a.k=b.k AND a.x>5` gibi **eşitlik + ek koşul**
içeren join'lerde hash yolu tamamen kapanıyordu; 10k × 10k'da sorgu **300
s'de bitmiyordu** (klasik çift döngü, 100M ifade değerlendirmesi). Artık
`AND` ağacının içindeki kolon=kolon eşitliği hash anahtarı olur, ek koşullar
`JoinOnOk`'ta aynen uygulanır (sonuç değişmez); ek koşul varsa indeks/PK
hızlı yolu kapatılır (o yol ek koşulu atlardı). Aynı sorgu **5.926 ms**.
Merge JOIN ve Bloom filtresi **ölçümle reddedildi** (gerekçeler:
`V3_YOL_HARITASI.md` §Sürüm çizgisi kararı). Kalan ölçülmüş fırsat: ON/WHERE
yüklemlerinin ilgili tarafa itilmesi.

**Sürüm çizgisi (2026-10-26):** Bu hat **alpha**'dır; `v3.x` numaraları
yayın sürümü değil çalışma dilimi adıdır. Kalan maddeler (dosya boyutu,
ifade bytecode, snapshot isolation; Bloom ve merge JOIN ölçümle reddedildi)
**bu hatta** yapılır; hepsi bitince ürün **v1.0.0** olarak yayınlanır.
`main` = `v3` (aynı commit); iş `v3`te yürür, her push'ta `main` de
ilerletilir. Süreçler arası çok yazarlılık kapsam dışı kalır (dosya kilidi
mimarisi).

Yukarıdaki olmayanlar **sessizce yanlış sonuç vermez**: her biri açık bir
`ecUnsupported` hatası ve yol gösteren mesaj döndürür.

---

## 10. GUI / veri bileşenleri

`TDBGrid`, `TDBNavigator`, `TDataSource`, FastReport gibi standart
bileşenler `VDbDataSet.TVDbQuery` üzerinden bağlanır:

```pascal
Qry := TVDbQuery.Create(nil);
Qry.SqlEngine := Sq;                  // v3 SQL örneği
Qry.SQL.Text := 'SELECT id, ad FROM kisi ORDER BY id';
Qry.Open;
DataSource1.DataSet := Qry;
```

Notlar:
- Salt-okunur gezinti her zaman çalışır.
- `Insert/Edit/Post/Delete` yalnız tek tablo + sade kolonlar + PK varsa
  çalışır; aksi hâlde `CanModify=False` (grid salt-okunur).
- Parametreler `?` yer tutucusuyla, sırayla verilir.

---

## 11. Yeni uygulama kontrol listesi

- [ ] Açılış `VDbFactory` ile; `TVDb` / `TVSql.Create(path)` yok
- [ ] Dosyayı veri dizininde tut (`%ProgramData%\Uygulama\veri` gibi),
      yan dosyalar için yer var
- [ ] Kapanış: `Sq.Free` → `Tb.Free` → `Be := nil` (try/finally)
- [ ] Hatalar `EVDbException` ile yakalanıyor, `ErrorCode` loglanıyor
- [ ] Çok satırlı yazma tek işlemde
- [ ] Kullanıcıya `BACKUP TO` (veya otomatik günlük yedek) sunuluyor
- [ ] Şifreleme gerekiyorsa `VdbOpenWithPassword`, parola koddan gelmiyor
- [ ] Yalnız PITR/WAL arşivi/replikasyon kullanılmıyor (§9); `SAVEPOINT` ve
      `AS OF SEQUENCE` v3.2'de var
- [ ] Sürüm yükseltmesinde `VERIFY` çalıştırılıp raporu loglanıyor

---

## 12. Hazır örnekler

`examples/` altındaki 01–06, 09–12 numaralı projeler bu kılavuzun
tamamını çalışır hâlde gösterir:

| Örnek | Konu |
|---|---|
| 01 | açma/oluşturma, basit tablo |
| 02 | SQL sorguları, parametre |
| 03 | CRUD |
| 04 | transaction (SAVEPOINT yok — nasıl davrandığı gösterilir) |
| 05 | JOIN |
| 06 | şifreli dosya (parolasız/yanlış parola reddi) |
| 09 | JSON içe/dışa aktarma |
| 10 | ileri özellikler |
| 11 | LCL GUI + DBGrid |
| 12 | milyon satır demosu |
