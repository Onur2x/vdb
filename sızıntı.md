# OOM (out of memory) sızıntısı — teknik rapor

**Tarih:** 04.11.2026
**Proje:** Makinist Takip (Free Pascal 3.2.4, 32-bit, `{$mode delphi}`)
**Düzeltme commit'i:** `06ed49e` (`D:\veritabani` deposu, `v3` dalı)
**Sunucu commit'i:** `b6552bc` (`D:\veritabani\mtakip`, `main` dalı)

---

## 1. Belirti

Sunucu çalışmaya başladıktan **2–3 gün sonra** hem sunucu hem web arayüzü
`out of memory` hatası veriyordu; HTTP ucu JSON olarak hata dönüyordu.

Süreç 32-bit olduğu için kullanılabilir bellek ~2 GB ile sınırlıdır ve
sürekli artan bir sızıntı bu sınıra ulaştığında süreç ölür.

---

## 2. Kök neden

Free Pascal, **yönetilen tip** (`record`, `string`, dizi) döndüren bir
fonksiyonun sonucunu **NRVO** (Named Return Value Optimization) ile
doğrudan çağıranın değişkenine kurar:

```pascal
R := Db.Calistir(SQL);   // R'nin belleği, fonksiyonun "Result" belleğidir
```

Yani fonksiyon içindeki `Result`, çağıran taraftaki `R` değişkeninin
**ta kendisidir**. Fonksiyonun başında şu kalıp vardı:

```pascal
function TVSql.Exec(const Sql: string): TSqlResult;
begin
  FillChar(Result, SizeOf(Result), 0);   // <-- HATA
  ...
```

`FillChar`, `R` değişkeninin **önceki yönetilen değerini finalize etmeden**
belleği sıfırlar. Böylece:

1. `R`'nin önceki değerine ait `string` ve dizi bloklarının referans sayacı
   hiç düşmez,
2. bloklar **hiçbir zaman serbest bırakılmaz**,
3. her sorguda bir önceki sorgunun **tamamı** bellekte kalır.

`Result := Default(T)` veya `Result := ''` / `Result := nil` ataması ise
önce eski değeri **düzgün finalize eder**, sonra sıfırlar. Fark buradadır.

> Not: Aynı hata `ZeroMemory(Result, ...)`, `Move` veya
> `FillChar(Pointer(@Result), ...)` ile de yapılabilir. `Result`'ı yönetilen
> tipte *bayt düzeyinde* sıfırlayan **her** yaklaşım aynı şekilde sızdırır.

### Sızıntı zinciri (canlı sunucu)

```
GET /api/gunun-terimleri
  -> TMtDb.TerimListeJson          (mtakip\mtdata.pas)
    -> TMtDb.Calistir              (mtakip\mtdata.pas:327)
      -> TVSql.Exec                (VDbSql.pas:3285)   <-- FillChar burada
        -> TVSql.ExecRaw           (VDbSql.pas:4281)
          -> TVSqlExecutor.Execute (VDbExecutor.pas:21296)
            -> ExecSelect          (VDbExecutor.pas:14843)
              -> ScanRowsPart      (VDbTable.pas:10380)
                -> DecodeRow       (VDbTable.pas:4054)
```

Kiosk bu ucu **her turda** çağırdığı için sızıntı saniyeler içinde
tekrar tekrar tetikleniyordu.

---

## 3. Ölçülen etki

| Ölçüm | Sızıntılı | Düzeltilmiş |
|---|---|---|
| Motor testi, 365 satırlık sorgu × 100 | **129,9 KB/tur** | **0,0 KB/tur** |
| heaptrc (`-gh -gl`), tek tam sorgu | **1.463 blok / 40.279 B** | **4 blok / 140 B** |
| `/api/gunun-terimleri` × 200 istek | ~136 KB/istek | **0,0 KB/istek** |
| 10 dakika hiç istek yok | sürekli artış | **+0,10 MB salınım, RSS 18,8 MB sabit** |

Kalan 4 blok tek seferlik açılış tahsisleridir
(`TVTableDb.InitCore`, `TVSql.ExecRaw`) — normaldir, sızıntı değildir.

Sızıntı miktarı **satır sayısı × metin kolon sayısı** ile doğrusal
ölçekleniyordu:

| Sorgu | Sızıntı |
|---|---|
| `SELECT COUNT(*)` | 0,1 KB/tur |
| 1 metin kolonu, 365 satır | 19,8 KB/tur |
| 2 metin kolonu, 365 satır | 49,4 KB/tur |
| 4 metin kolonu, 365 satır | 72,2 KB/tur |
| `WHERE 1=0` (0 satır) | 0,0 KB/tur |

---

## 4. Düzeltme

### 4.1 ANA NEDEN — tek başına sızıntının büyük kısmını durdurur

| Dosya | Satır | Fonksiyon |
|---|---|---|
| `VDbSql.pas` | **3285** | `TVSql.Exec(const Sql: string): TSqlResult` |

Her SQL sorgusu buradan geçer.

### 4.2 Aynı kalıbın diğer kopyaları (28 yerin tamamı)

| Dosya | Satırlar | Dönüş tipi | Doğru sıfırlama |
|---|---|---|---|
| `VDbSql.pas` | 3167, 3233, 3355, 3388, 3550, 3595, 3644, 3675, 3694, 3738, 3768, 3905 | `TSqlResult` | `Result := Default(TSqlResult);` |
| `VDbExecutor.pas` | 2951, 21246, 21337 | `TSqlResult` | `Result := Default(TSqlResult);` |
| `VDbExecutor.pas` | 759 (`RowEncodeKey`) | `string` | `Result := '';` |
| `VDbExecutor.pas` | 1903 (`EvalExpr`) | `string` | `Result := '';` |
| `VDbExecutor.pas` | 18752 (`EvalExprFor`) | `string` | `Result := '';` |
| `VDbPool.pas` | 446, 461 | `TSqlResult` | `Result := Default(TSqlResult);` |
| `VDbClientNet.pas` | 191, 325 | `TSqlResult` | `Result := Default(TSqlResult);` |
| `VDbTimeTravel.pas` | 117 | `TSqlResult` | `Result := Default(TSqlResult);` |
| `VDbBTree.pas` | 416 | `TVDbSkipEntry` | `Result := Default(TVDbSkipEntry);` |
| `VDbTable.pas` | 1281 (`VDbS2B`) | `TBytes` | `Result := nil;` |
| `VDbCrypt.pas` | 1418, 1449 | `TBytes` | `Result := nil;` |

Kalan olup olmadığını doğrulamak için:

```
grep -rn "FillChar(Result" --include=*.pas
```

Sonuç **boş** olmalıdır.

### 4.3 İkincil düzeltme — `VDbTable.pas`

`VDbB2S` fonksiyonu `RawByteString` döndürüyordu, sonuçlar `string`
değişkenlere atanıyordu. FPC'de `RawByteString` (CP_NONE) → `string`
ataması kod sayfası dönüşümü tetikler ve fazladan tahsis yapar.

Satır ~1286 civarı:

```pascal
procedure VDbB2SInto(const B: TBytes; Pos, Len: Integer; var S: string);
begin
  SetLength(S, Len);
  if Len > 0 then Move(B[Pos], S[1], Len);
end;

function VDbB2S(const B: TBytes; Pos, Len: Integer): string;
begin
  VDbB2SInto(B, Pos, Len, Result);
end;
```

Ayrıca şu fonksiyonlarda yerel `s: RawByteString` → `s: string` yapıldı:

- `VDbRowFromOffsetsP` (satır ~4171)
- `VDbRowFromOffsetsMaskP` (satır ~4221)
- `VDbColFromOffsetsP` (satır ~4269)

**DİKKAT:** `VDbHashKey` fonksiyonu **bilinçli olarak `RawByteString`
bırakılmalıdır.** Orada UTF-8 baytları aynen korunmalıdır; `string`'e
çevirmek Türkçe karakterlerde hash'i bozar ve satırlar bulunamaz.

Bu kısım sızıntının yaklaşık yarısını giderdi (129,9 → 59,3 KB/tur);
asıl çözüm 4.1/4.2'deki `FillChar` düzeltmesidir (59,3 → 0,0 KB/tur).

---

## 5. Yapılmaması gerekenler

- `FillChar(Result, SizeOf(Result), 0)` kullanmak — asıl hata.
- `ZeroMemory(Result, SizeOf(Result))` veya `Move` ile sıfırlamak — aynı hata.
- `FillChar(Pointer(@Result), ...)` — aynı hata.
- Sadece `SetLength(Result.Rows, 0)` yazmak — `Msg`, `LastTable`, `Fields`
  gibi string alanları sızmaya devam eder. `Default(T)` hepsini halleder.
- Çağıran tarafta `Finalize(R)` / `R := Default(T)` ile kurtarmaya çalışmak
  — **işe yaramaz**, sızıntı fonksiyonun içinde oluşur.

---

## 6. Doğrulama yöntemi

Birim testinin kendisi de sızıntıyı göstermelidir; düzeltmeden sonra sıfır
çıkmalıdır:

1. Aynı sorguyu 100 kez çalıştır, her 20 turda `GetHeapStatus.TotalAllocated`
   farkını yazdır. Düzeltilmiş kodda artış **0** olmalı.
2. `-gh -gl` (heaptrc) ile derleyip tek tam sorgu çalıştır; `unfreed memory
   blocks` satırı **0'a yakın** (yalnız açılış) olmalı.
3. HTTP ucu üzerinden 200 istek at, süreç commit boyutundaki farkı ölç.
4. 10 dakika hiç istek atmadan bekle; bellek salınım dışında **artmamalı**.

---

## 7. Sunucu tarafı (ikinci commit)

`D:\veritabani\mtakip` deposu, `b6552bc`:

- `mtdata.pas` — `TerimListeJson` için **sürüm bazlı önbellek** eklendi
  (`FTerimJson`, `FTerimVers` alanları; `Versiyon` değişince otomatik
  geçersizleşir). Kiosk her turda tam tablo taraması yapmıyor.
- `websrv.pas` — `SRV_VERSIYON` `'0006'`; `/api/bellek` teşhis ucu;
  `/api/kiosk-anahtar` içinde `FreeAndNil(jd)` düzeltmesi.
- `mtakipwebsrv.lpr` — bellek bekçisi: **600 MB** uyarı, **1000 MB**
  kendini yeniden başlatma (32-bit 2 GB sınırına karşı emniyet supabı),
  `OKUMA_MS = 1000` soket zaman aşımı.

---

## 8. Kapsam dışı — veritabanı dosyaları

Sızıntı **veri dosyalarından kaynaklanmıyordu**. İnceleme sırasında veri
dosyalarına hiçbir müdahalede bulunulmadı; `mtakip.odb` bütünlük
doğrulaması (`Verify`) **TRUE** döndü, ölü bayt 0, 132 tablo okunabilir.

Bildirilen ancak **silinmeyen** artıklar (temizlik için onay bekliyor):

| Dosya | Boyut | Not |
|---|---|---|
| `data\mtakip.odb.log\base\` (16 dosya) | ~120 MB | eski base snapshot'lar, 26–31.10 |
| `data\mtakip.odb.bak` | 9,8 MB | eski otomatik yedek (31.10) |
| `data\mtakip.odb.compact.tmp.gen` | 8 B | yarım kalmış Compact artığı |
| `data\vdbmig.exe` | 8,3 MB | veri klasöründe duran araç programı |
