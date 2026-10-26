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

- Veritabanı **tek yazıcı** ile çalışır: dosya bayt-aralığı kilidiyle
  tutulur. İkinci açılış ham "paylaşım ihlali" değil, açık bir hata verir:
  `veritabani dosyasi kullanimda (baska islem acik): ...`
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

## 9. v3.2'de hâlâ olmayanlar (planlı sınırlar)

| Özellik | Durum | Not |
|---|---|---|
| `AS OF SEQUENCE n` | **var** (v3.2) | WAL penceresindeki n'inci commit'in tam görüntüsü geçici kopyada kurulur; yalnız son checkpoint'ten beri. n = commit sayısı |
| PITR (`RECOVER TO`), WAL arşivi, `AS OF TIMESTAMP/VERSION` | yok | checkpoint öncesine gitmek/zaman ekseni mantıksal günlük ister; günlük `BACKUP TO` ile yetinin |
| Replication (`START REPLICATION` vb.) | yok | mantıksal değişim günlüğü gerektirir; tek dosya, tek yazıcı |
| Zone map / bölüm budama | yok | sonuçlar doğru, tam tarama |
| MVCC (süreç içi çok oturum) | **var** (v3.4) | READ COMMITTED; her oturum kendi yazma kümesinde yazar, **ilk commit kazanır**, kaybeden `yazma cakismasi` ile durur. DDL/`SAVEPOINT`/`DEFERRABLE` çoklu yazmada reddedilir. Snapshot isolation yok |
| MVCC (süreçler arası) | yok | dosya kilidi ikinci süreci reddeder |

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
