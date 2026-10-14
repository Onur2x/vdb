# vdbapi.dll Ã¢â‚¬â€ Kendi ProgramÃ„Â±nÃ„Â±zda KullanÃ„Â±m

## Ne Ã„Â°Ã…Å¸e Yarar

Bu veritabanÃ„Â± motoru Pascal/FPC ile yazÃ„Â±ldÃ„Â±. **Delphi derleyicisi FPC ile
ÃƒÂ¼retilmiÃ…Å¸ `.ppu` dosyalarÃ„Â±nÃ„Â± baÃ„Å¸layamaz** Ã¢â‚¬â€ iki derleyicinin birim biÃƒÂ§imi
uyumsuzdur. Bu yÃƒÂ¼zden tek yol bir **DLL**'dir.

`vdbapi.dll` motorun tamamÃ„Â±nÃ„Â± **C ABI** ile dÃ„Â±Ã…Å¸a aÃƒÂ§ar. AynÃ„Â± dosya Delphi,
C#, Python, C, Rust ve diÃ„Å¸er dillerden ÃƒÂ§aÃ„Å¸rÃ„Â±labilir; her dil iÃƒÂ§in yalnÃ„Â±zca
birkaÃƒÂ§ satÃ„Â±rlÃ„Â±k bir baÃ„Å¸layÃ„Â±cÃ„Â± gerekir.

## Dosyalar

| Dosya | Ã„Â°Ã…Å¸lev |
|---|---|
| `vdbapi.dll` | **Motorun kendisi.** ProgramÃ„Â±nÃ„Â±zÃ„Â±n yanÃ„Â±nda olmalÃ„Â±. |
| `vdbapi.h` | C/C++ iÃƒÂ§in fonksiyon bildirimleri |
| `VDBClient.pas` | **Delphi/Pascal iÃƒÂ§in hazÃ„Â±r birim.** `uses VDbClient;` yeter. |
| `build_dll.ps1` | DLL'i yeniden derler |
| `vdbapitest.exe` | ABI testi (170 kontrol) |
| `vdbclienttest.exe` | Delphi birim testi (101 kontrol) |
| `vdbclientdemo.exe` | Ãƒâ€¡alÃ„Â±Ã…Å¸tÃ„Â±rÃ„Â±labilir kullanÃ„Â±m ÃƒÂ¶rneÃ„Å¸i |

## Delphi'de KullanÃ„Â±m (Senin Durumun)

### 1. DosyalarÃ„Â± kopyala

`vdbapi.dll` ve `VDBClient.pas` dosyalarÃ„Â±nÃ„Â± Delphi projenin klasÃƒÂ¶rÃƒÂ¼ne kopyala.

### 2. Projeye ekle

`VDBClient.pas` dosyasÃ„Â±nÃ„Â± projeye "Existing Unit" olarak ekle ve
`uses VDbClient;` yaz.

### 3. Platform: 32-bit

**DLL 32-bit (x86) olarak derlenmiÃ…Å¸tir.** Delphi projen de 32-bit olmalÃ„Â±:

```
Project > Options > Delphi Compiler > Target Platforms > 32-bit Windows
```

64-bit projede `vdbapi.dll` yÃƒÂ¼klenemez.

### 4. Kullan

```pascal
uses VDbClient;

var
  Db: TVDb;
  R: TVDbResult;
begin
  Db := TVDb.Open('C:\veriler\veritabani.odb');
  try
    Db.SQL('CREATE TABLE kisi (id INTEGER PRIMARY KEY, ad TEXT NOT NULL, yas INTEGER)').Free;

    Db.SQL('INSERT INTO kisi (id, ad, yas) VALUES ' +
           '(1, ''Ali'', 30), (2, ''Veli'', 25)').Free;

    R := Db.SQL('SELECT id, ad FROM kisi ORDER BY id');
    try
      ShowMessage(IntToStr(R.RowCount) + ' satir');
      ShowMessage(R.FieldName(1) + ' = ' + R.Value(0, 1));   // ad = Ali
    finally
      R.Free;
    end;

    // KÃ„Â±sÃ„Â±t hatasÃ„Â± istisna olarak gelir
    try
      Db.SQL('INSERT INTO kisi (id, ad) VALUES (3, NULL)').Free;
    except
      on E: EVDbApiError do
        ShowMessage('KÃ„Â±sÃ„Â±t hatasÃ„Â± (kod ' + IntToStr(E.Code) + '): ' + E.Message);
    end;
  finally
    Db.Free;
  end;
end;
```

Ãƒâ€¡alÃ„Â±Ã…Å¸an tam ÃƒÂ¶rnek: `vdbclientdemo.exe`

```
cd veritabani
vdbclientdemo.exe
```

## Ãƒâ€“nemli Kurallar

### Metinler UTF-8

TÃƒÂ¼m metinler **UTF-8** ve NUL ile sonlanÃ„Â±r. Kaynak kodunuzda TÃƒÂ¼rkÃƒÂ§e
karakter kullanacaksanÃ„Â±z dosyayÃ„Â± UTF-8 olarak kaydedin:

```pascal
Db.SQL('INSERT INTO kisi (id, ad) VALUES (1, ''Ahmet Ãƒâ€¡elik'')');
```

### AynÃ„Â± VeritabanÃ„Â± AynÃ„Â± Anda Tek Programda AÃƒÂ§Ã„Â±k Olabilir

Motor dosyayÃ„Â± **iÃ…Å¸lemler arasÃ„Â± kilitler** (`LockFileEx`). Ã„Â°kinci bir
program aynÃ„Â± dosyayÃ„Â± aÃƒÂ§maya ÃƒÂ§alÃ„Â±Ã…Å¸Ã„Â±rsa `VDB_E_OPEN` hatasÃ„Â± alÃ„Â±r:

```pascal
if not TVDb.TryOpen(Yol, True, Db, Hata) then
  ShowMessage('AÃƒÂ§Ã„Â±lamadÃ„Â±: ' + Hata);   // baÃ…Å¸ka program aÃƒÂ§Ã„Â±k
```

Yani `had.exe` ile kendi programÃ„Â±nÃ„Â± **aynÃ„Â± anda ÃƒÂ§alÃ„Â±Ã…Å¸tÃ„Â±ramazsÃ„Â±n**. YÃƒÂ¶netimi
kullanacaksan ÃƒÂ¶nce onu kapat.

### WAL Ã„Â°steÃ„Å¸e BaÃ„Å¸lÃ„Â±

`Put`/`Delete` otomatik olarak WAL yazmaz. `WalWrite` ÃƒÂ§aÃ„Å¸rÃ„Â±ldÃ„Â±Ã„Å¸Ã„Â±nda kayÃ„Â±t
`.wal` dosyasÃ„Â±na yazÃ„Â±lÃ„Â±r ve **ana dosyaya yazÃ„Â±lmaz**; veri ancak
`WalReplay` veya `WalCheckpoint` ile kalÃ„Â±cÃ„Â± hÃƒÂ¢le gelir.

```pascal
Db.WalWrite(1001, 'ÃƒÂ¶nemli bilgi');   // ana dosyaya YAZILMAZ
Db.WalReplay;                         // Ã…Å¸imdi yazÃ„Â±lÃ„Â±r
```

Normal veri iÃƒÂ§in `Put` kullan; WAL yalnÃ„Â±zca "ana dosyaya yazmadan kayÃ„Â±t
tutmak" istediÃ„Å¸inde gerekir (ÃƒÂ¶rn. toplu yÃƒÂ¼kleme sÃ„Â±rasÃ„Â±nda ÃƒÂ§ÃƒÂ¶kerse veri
kaybolmasÃ„Â±n).

### Hata YÃƒÂ¶netimi

Her ÃƒÂ§aÃ„Å¸rÃ„Â± `VDB_OK` (0) dÃƒÂ¶nerse baÃ…Å¸arÃ„Â±lÃ„Â±dÃ„Â±r. `VDBClient` hatalarÃ„Â±
`EVDbApiError` istisnasÃ„Â± olarak fÃ„Â±rlatÃ„Â±r; `E.Code` ABI hata kodudur.

| Kod | AnlamÃ„Â± |
|---|---|
| `-2` | GeÃƒÂ§ersiz handle |
| `-3` | VeritabanÃ„Â± aÃƒÂ§Ã„Â±lamadÃ„Â± (baÃ…Å¸ka program aÃƒÂ§Ã„Â±k olabilir) |
| `-4` | SQL hatasÃ„Â± |
| `-9` | Anahtar/tablo bulunamadÃ„Â± |
| `-10` | UNIQUE veya PK ihlali |
| `-11` | FK / CHECK / NOT NULL ihlali |

### `VdbGet` Ã„Â°ki AÃ…Å¸amalÃ„Â±dÃ„Â±r

DoÃ„Å¸rudan DLL'i kullanÃ„Â±rsan deÃ„Å¸eri okumak iki ÃƒÂ§aÃ„Å¸rÃ„Â± ister:

```c
int need = VdbGet(h, key, NULL, 0);   /* gerekli boyut */
if (need == -1) { /* anahtar yok */ }
else if (need < 0) { need = -need; }  /* negatif = boyut */
char buf[need];
VdbGet(h, key, buf, need);            /* asÃ„Â±l okuma */
```

`VDBClient.pas` bunu sizin iÃƒÂ§in yapar Ã¢â‚¬â€ `GetStr` / `GetBytes` kullanÃ„Â±n.

## BaÃ…Å¸ka Diller Ã„Â°ÃƒÂ§in

`vdbapi.h` dosyasÃ„Â±ndaki imzalarÃ„Â± kullan. Ãƒâ€“rnek C:

```c
#include "vdbapi.h"

uint32_t db = VdbOpen("C:\\veriler\\veritabani.odb", 1);
if (db == 0) {
    printf("Hata %d: %s\n", VdbLastErrorCodeGet(), VdbLastError());
    return 1;
}

uint32_t r = VdbExec(db, "SELECT id, ad FROM kisi", 0);
if (r) {
    int n = VdbResultRowCount(r);
    for (int i = 0; i < n; i++)
        printf("%s\n", VdbResultValue(r, i, 1));
    VdbResultFree(r);
}
VdbClose(db);
```

## Derleme

DLL'i yeniden derlemek iÃƒÂ§in:

```powershell
powershell -ExecutionPolicy Bypass -File build_dll.ps1
```

> **Not:** Lazarus'un `.lpi` XML'inde kÃƒÂ¼tÃƒÂ¼phane tÃƒÂ¼rÃƒÂ¼ iÃ…Å¸areti bu kurulumda
> okunmadÃ„Â±Ã„Å¸Ã„Â± ve proje `.exe` olarak baÃ„Å¸landÃ„Â±Ã„Å¸Ã„Â± iÃƒÂ§in DLL derlemesi FPC'yi
> doÃ„Å¸rudan ÃƒÂ§aÃ„Å¸Ã„Â±ran `build_dll.ps1` ile yapÃ„Â±lÃ„Â±r. AynÃ„Â± nedenle derleme
> betiÃ„Å¸inde `-Mdelphi` **bilinÃƒÂ§li olarak verilmez**: `VDbCrc32.pas` iÃƒÂ§indeki
> bir yorumda `{$mode delphi}` dizisi geÃƒÂ§iyor ve delphi modunda derleme
> kÃ„Â±rÃ„Â±lÃ„Â±yor (FPC yorumu `}` ile kapatÃ„Â±p satÃ„Â±rÃ„Â±n kalanÃ„Â±nÃ„Â± kod sanÃ„Â±yor).

## DoÃ„Å¸rulama Durumu

| Test | Kapsam | SonuÃƒÂ§ |
|---|---|---|
| `sqltest.exe` | Motor (1810 kontrol) | ✅ 1810/0 |
| `vdbapitest.exe` | DLL ABI (170 kontrol) | Ã¢Å“â€¦ 170/170 |
| `vdbclienttest.exe` | Delphi birimi (101 kontrol) | Ã¢Å“â€¦ 101/101 |

`vdbapitest.exe` DLL'i **`LoadLibrary` ile dinamik yÃƒÂ¼kler** ve her export'u
`GetProcAddress` ile adres alarak ÃƒÂ§aÃ„Å¸Ã„Â±rÃ„Â±r Ã¢â‚¬â€ yani gerÃƒÂ§ekten harici bir
programÃ„Â±n yaptÃ„Â±Ã„Å¸Ã„Â±nÃ„Â± yapar. Eksik bir export sessizce geÃƒÂ§mez, test
hata durur.

---

## Otomatik WAL (write-ahead) - `VdbWalSetAuto`

WAL'i **elle** kullanmak (`VdbWalWrite`) hataya acik: cagirmayi unutursan
kayit yalniz bellekte kalir. Otomatik modda motor **her yazmada** once
`.wal`'a, sonra ana dosyaya yazar.

```c
/* ac: bundan sonraki her Put/DeleteOnce once .wal'a */
VdbWalSetAuto(hDb, 1);

/* ... normal yazma islemleri ... */

int n = VdbWalAutoCount(hDb);   /* bu agaza kadar gunluge yazilan kayit */
int acik = VdbWalIsAuto(hDb);   /* 1 = acik */

/* gunlugu temizle (veri zaten ana dosyada) */
VdbWalCheckpoint(hDb);

/* kapat: geriye donuk uyumlu eski davranis */
VdbWalSetAuto(hDb, 0);
```

Delphi'de:

```pascal
Db.WalAutoEnabled := True;   // veya Db.SetWalAuto(True)
Db.Put(1, 'deger');          // once .wal, sonra ana dosya
Db.WalAutoCount;              // 1
```

Kurallar:

- **Varsayilan KAPALI.** Cagirmazsaniz hicbir sey degismez.
- **WAL yazilamazsa** yazma hata doner ve **ana dosyaya yazilmaz**.
- `Close` durumu **sifirlar**; yeniden `Open` edince `VdbWalIsAuto = 0`.
- Elle `VdbWalWrite` kullanacaksaniz otomatik modu **kapatin** (cift yazim).
- `VdbWalReplay` otomatik modda kayitlari **iki kez** uygular (veri
  bozulmaz, `PUT`/`DEL` idempotent; ama ayni kayit tekrar yazilir). Bu
  yuzden otomatik modda `VdbWalCheckpoint` kullanin.

Hata sozlesmesi: hata halinde donus degeri **negatiftir**
(`VDB_E_GENERAL`), spesifik kod `VdbErrCode()` ile alinir
(`VDB_E_BAD_HANDLE` vb.). Sorgu donduruculer (`VdbWalIsAuto`,
`VdbWalAutoCount`, `VdbWalHas`, `VdbWalRecordCount`) `0` donerek hatayi
gizlemez.

---

## Ã…Âifreleme - `VdbEncrypt*` (2026-10-05)

Kayitlari AES-256-CTR + HMAC-SHA256 ile sifreler. **Donus sozlesmesi
farklidir**: bu fonksiyonlar `1 = basari`, `0 = hata` dondurur (hata
ayrintisi `VdbLastError()` / `VdbErrCode()`).

```c
/* 1) parola (.key) modu - oncelikle kullanilan yol */
VdbEncryptCreateKeyFile(hDb, "C:\\db\\veritabani.key", "guclu-parola");
/* artik yazilan TUM kayitlar sifrelidir */

/* acilista: yanlis parola -> 0 doner (istisna/crash yok) */
if (!VdbEncryptOpenKeyFile(hDb, "C:\\db\\veritabani.key", "guclu-parola"))
    printf("parola hatali: %s", VdbLastError());

/* 2) ham 32 bayt anahtar modu (parola olmadan, uygulama yonetir) */
unsigned char key[32] = { /* ... */ };
VdbEncryptEnable(hDb, key, 32);
memset(key, 0, sizeof key);          /* DLL kopyasini bellekte tutar */

/* durum sor */
int enc  = VdbEncryptIsEncrypted(hDb);           /* 1 = anahtar aktif */
int hev  = VdbHasEncryptedRecords(hDb);          /* 1 = dosyada sifreli kayit var */

char fp[32];
VdbEncryptFingerprint(hDb, fp, sizeof fp);       /* or. "D641A587" (hash, sifir degil) */

/* parola rotasyonu (eski anahtar aktifken cagir) */
VdbRekeyWithPassword(hDb, "yeni-parola");        /* .key guncellenir, .bak kalir */

/* kapat */
VdbEncryptDisable(hDb);
```

Kurallar:

- `.key` dosyasi **sir tutmaz** (tuz + iterasyon + dogrulayici). Sirl
  paroladir; parolayi sizdirmayin.
- `VdbEncryptEnable` sadece **yeni** yazilari sifreler; mevcut karisik
  (duz + sifreli) dosyalar aynen okunur (her kayit kendi bayragini tasir).
- Sifreli kayit **anahtarsiz okunursa** hata doner
  (`SIFRELI: anahtar yok`) Ã¢â‚¬â€ sessizce bozuk veri degil.
- `VdbRekeyWithPassword` once yeni `.key`'i (`.key.tmp`), sonra veriyi
  tmp cikisi + atomik rename ile yeniden yazar; eski `.odb` `.odb.bak`,
  eski `.key` `.key.bak` olarak kalir. Batch acikken cagrilamaz.
- `VdbVerify` raporunda `sifreli=N` alani vardir.
- **WAL (`VdbWalWrite`) veriyi duz metin yazar** (acil durum kurtarma
  icin bilincli); WAL dosyasi da parola korumali degildir.

Delphi (`VDBClient.pas`): `Db.SetEncryptKey`, `Db.CreateKeyFile`,
`Db.OpenKeyFile`, `Db.IsEncrypted`, `Db.HasEncryptedRecords`,
`Db.KeyPath`, `Db.GetEncryptionKeyFingerprint`,
`Db.RekeyWithPassword`, `Db.ClearEncryptKey`.

Test: `vdbapitest.exe` (170/170), `vdbclienttest.exe` (101/101),
`vdbcrypttest.exe` (60/60).

---

## CDC / Time Travel - `VdbCdc*` + `VdbValueAt` (2026-10-06)

CDC (Change Data Capture), `.wal` dosyasindaki satir degisikliklerini
(INSERT/UPDATE/DELETE) olay olarak verir; Time Travel (`VdbValueAt`) ayni
gecmisten bir satirin o anki degerini okur. **Callback DLL sinirini
gecmez**: olaylar istemci tarafindan **poll** edilir (C/Delphi icin en
guvenli yon). ABI surumu bu eklemeye 1.0 -> **1.1** oldu (geriye uyumlu).

```c
VdbCdcStart(hDb);              /* otomatik WAL acilir; ~50ms'de bir taranir */

/* ... VdbPut / VdbExec ile yazmalar ... */

for (;;)
{
    int n = VdbCdcPollSize(hDb);       /* >0 olay boyutu, 0 = olay yok */
    if (n <= 0) break;                 /* negatif = hata kodu */
    char buf[4096];
    if (n > (int)sizeof buf) n = (int)sizeof buf;
    int got = VdbCdcPoll(hDb, buf, n); /* kopyalar VE tuketir */
    if (got == 0) break;               /* olay yok */
    if (got < 0) break;                /* VDB_E_BUFFER: olay tamponda KALIR */
    /* buf[0..got-1] = paket; alanlar #30 (RS) ile ayrili */
}

VdbCdcStop(hDb);               /* durdurur; kalan olaylar tamponda KALIR */
```

Paket (UTF-8, NUL'suz, alan ayirici `#30` = RS):

    kind #30 seq #30 table #30 pk #30 oldJson #30 newJson

| Alan | Anlam |
|---|---|
| `kind` | `0` insert, `1` update, `2` delete |
| `seq` | CDC olay sira numarasi (WAL'de bu alan YOKTUR, DLL'de uretilir) |
| `table` / `pk` | tablo adi ve satirin birincil anahtari |
| `oldJson` / `newJson` | kolon degerleri JSON dizisi: `["1","bir"]` (bos taraf `[]`) |
| Zaman damgasi | **pakette YOKTUR** - istemci kendi UTC epoch-ms damgasini eklesin |

`VdbCdcStats(hDb, &ev, &skip, &pend, &drop)` tanilama sayaclari (NULL
gecilebilir): uretilen olay, atlanan WAL kaydi (sema kaydi degeri olmayan
silme), tampondaki bekleyen, tampon siniri asilirsa dusen.

Kurallar:

- **Tek istemci**: ayni anda iki `VdbCdcPoll` cagirilmaz.
- Tampon siniri 100000 olaydir; tasarsa **en eski** olay duser ve `drop`
  artar - sessiz kayip yoktur.
- `VdbClose` CDC nesnesini thread'iyle birlikte serbest birakir; calisirken
  kapatmak guvenlidir. Handle kapaninca CDC baglantisi da sifirlanir
  (yeniden acinca `VdbCdcStart` tekrar cagirilir).
- CDC baslamadan `VdbCdcPoll*`/`VdbCdcStats` cagirilirsa hata doner
  (`VDB_E_ENGINE`), `VdbCdcStop` ayni sekilde.
- CDC yalnizca **son checkpoint'ten sonraki** yazilari gorur; silme
  olayinin PK'si daha once WAL'e dusen bir PUT varsa uretilebilir
  (CDC'yi yazmadan once baslatmak en dogrusu).

### Time Travel - `VdbValueAt`

```c
char js[256];
int need = VdbValueAt(hDb, "tablo", "pk", 6, NULL, 0);
/* donus sozlesmesi VdbGet ile ayni:
     <0  -> gerekli boyut = -sonuc  (ALen=0 boyut sorgusu)
     -1  -> o noktada satir YOK (silinmis/hic yazilmamis)
     >0  -> kopyalanan bayt */
if (need < -1) {
    need = -need;
    int got = VdbValueAt(hDb, "tablo", "pk", 6, js, need);
    /* js = ["1","bir"] */
}

int history = VdbHistoryCount(hDb);   /* okunabilir gecmis sayisi (>=0) */
```

- `aSeq` = WAL kayit **indeksi** (0 tabanli, o indeks **dahil** uygulanmis
  goruntu); `n >= WalRecordCount` son kayda kirpilir.
- Gecmis yalnizca **son checkpoint'ten** beriyi kapsar (`VdbHistoryCount`
  0 donebilir) - "tarihin tamami" degildir.
- `VdbValueAt` her cagrida WAL'i tarar (scan); sik sorgulanacak degerler
  icin istemci kendi onbelleini tutmalidir.

Delphi (`VDBClient.pas`): `Db.CdcStart`, `Db.CdcStop`, `Db.CdcPollSize`,
`Db.CdcPoll(pkt)` (True = olay var, hata `EVDbApiError`),
`Db.CdcStats(ev, skip, pend, drop)`, `Db.ValueAt(tbl, pk, seq, js)`
(True = satir var; yasayan API yalnizca True/False dondurur),
`Db.HistoryCount`.

Test: `vdbapitest.exe` (170/170 - "CDC (poll) + TIME TRAVEL" grubu),
`vdbclienttest.exe` (101/101).






