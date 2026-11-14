# v4 container: calisirken de tek fiziksel dosya

> **DURDURULDU (sahip karari, 2026-11-14).** Bu is **uygulanmayacak**.
> Sebep: veri kaybi riski kabul edilmedi. Motor acikken WAL ve sayaci ayni
> dosyaya almak (`VDB_FILE_VER = 6`) iki sey getiriyordu - calisirken tek
> fiziksel dosya ve daha zor bir cokme modeli - ve karsiliginda tek baslik
> kopyasi (torn page 0) riskini buyutuyordu. `A` (PHASE-9) zaten **kalici
> durumu** tek dosya yapti: temiz kapanistan sonra dizinde yalniz `.odb`
> kalir. Sahip "riskli isler istemiyorum" dedi; bu belge yalnizca tarihce
> ve ileride yeniden acilirsa baslangic noktasi olarak duruyor.
>
> Buna ragmen yazilmis **tek kod parcasi** `VDbRegion.pas` +
> `tests/region_stream` (13 kontrol): motorda **kullanilmiyor**, bagimsiz ve
> yesil. Format degismedigi icin `VDB_FILE_VER` **5** kalir.
>
> Durum: **tasarim, uygulanmadi.**

Bu belge format degisikliginin (v6) sozlesmesidir. Kod yazmadan once
yerlesim, cokme sirasi ve geri uyumluluk net olmali; aksi halde yarim
kalan sayfa yazimi ile gunluk kaydini ayni dosyada yaristirip veri
kaybederiz.

---

## 1. Bugunku durum (v5 + A)

| Durum | Dosyalar |
|---|---|
| Motor acikken | `<db>.odb` + `<db>.odb.wal` + `<db>.odb.gen` |
| Temiz kapanista | `<db>.odb` |
| Cokmus | `<db>.odb` + dolu `.wal` (+ `.gen`) |

`A` (PHASE-9) kalici durumu tek dosya yapti. Kalan fark yalnizca calisma
anidir. v4 container bunu da kapatir.

## 2. Yerlesim (v6)

```
sayfa 0                  : baslik (meta)
sayfa 1 .. TailBase-1    : veri sayfalari (bugunku numaralandirma AYNEN)
sayfa TailBase .. +G-1   : gen bolgesi   (9 sayfa = 32.792 B)
sayfa TailBase+G .. +W-1 : WAL bolgesi   (W sayfa, varsayilan 256 = 1 MB)
```

Onemli: **veri sayfasi numarasi degismez**, dosya ofseti hala
`pageNo * 4096`. Bolgeler yalnizca dosyanin sonunda, `FPageCount`'in
otesinde durur. Boylece v5 -> v6 gecisi sayfa adreslemesine dokunmaz;
v5 okuyucular da (bolgeleri gormeden) dosyayi okumaya devam eder.

Baslik sayfasi yeni alanlari (offset 84+, bugun bos):

| Offset | Alan | Tip | Anlam |
|---|---|---|---|
| 84 | `LayoutVer` | LongWord | 0 = v5 (bolge yok), 1 = v6 bolgeli |
| 88 | `TailBasePage` | LongWord | bolge blogunun ilk sayfasi |
| 92 | `GenPages` | LongWord | gen bolgesi sayfa sayisi (9) |
| 96 | `WalPages` | LongWord | WAL bolgesi sayfa sayisi |
| 100 | `TailReserved` | LongWord | rezerv (tanı icin) |

`VDB_FILE_VER` 5 -> 6 yalnizca **bolge yazildiginda** yukseltilir. Bolgesiz
yazilmis bir v6 dosyasi yoktur; 5 kalan dosyalar eski (yan dosyali) yol ile
acilir.

## 3. Dosya boyutu

```
dataBytes = max(FPageCount,1) * 4096
tailBytes = (GenPages + WalPages) * 4096
fileSize  = max(dataBytes, (TailBasePage + GenPages + WalPages) * 4096)
```

`RequiredFileSize` bu iki bileseni ayri hesaplar; `GrowTo` veri buyumesini
`TailBasePage`'e kadar serbest birakir.

## 4. Veri buyumesi ve blok tasima

`TailBasePage` sabit degildir. Aciilista:

```
margin     = max(FPageCount div 4, 4096)      // >= 16 MB
TailBase   = FPageCount + margin
```

Yani her acilis veri alani icin dosya boyutunun en az %25'i kadar (en az
4096 sayfa) bosluk rezerve eder. Blok yalnizca veri bu rezervi tuketince
tasınir; her tasimada `margin` iki katina cikar (amortize maliyet).

**Tasima yalnizca WAL bos iken yapilir.** Kural:

1. Veri sayfasi ayirmak uzereyken (`NewPageNo`) `FPageCount + 1 >=
   TailBasePage` ise: WAL **bos degilse** islem `EVdbRegionFull` ile
   **reddedilir ve rollback edilir** (sessiz yanlis sonuc yok); WAL bossa
   tasima yapilir.
2. Tasima sirasi (cokme guvenli):
   a. yeni gen basligi + sifir kapsam bolgesi yeni adrese yazilir, `fsync`
   b. yeni WAL basligi yeni adrese yazilir, `fsync`
   c. **page 0** yeni `TailBase`/`GenPages`/`WalPages` ile yazilir, `fsync`
   Arada cokme: page 0 hala ESKI blogu gosterir; eski blok gecerli (WAL
   bos, gen yeniden uretilebilir). Yeni blok cop olarak kalir ve veri
   buyudukce uzerine yazilir; hicbir zaman okunmaz.
3. Tasima **islem basinda** yapilir, islem ortasinda asla.

## 5. WAL bolgesi

`TVdbPageWal` bugun `TFileStream` uzerinde calisiyor (`.Size`, `Seek`,
ikinci fsync handle'i). Degisiklik:

- Yeni `TVdbRegionStream` (`VDbRegion.pas`): taban ofset + kapasite
  penceresi; `Size` **fiziksel dosyayi kesmez**, yalnizca mantiksal uzunluk;
  kapasite asilirsa `EVdbRegionFull`.
- `TVdbPageWal.Create` iki bicim kabul eder: dosya yolu (bugun) veya hazir
  `TStream` + `ADbId` (v6). Yol bicimi v5 dosyalari icin korunur.
- `fsync`: bolge ayni dosyada oldugu icin alt handle'a `VDbFlushStream`
  yeterli (zaten tum dosyayi flush eder).
- Bolge dolarsa: commit **reddedilir**, islem geri alinir, hata acikca
  raporlanir (`EVdbRegionFull: WAL bolgesi dolu`). Sonraki islem basinda
  bolge iki katina cikarilip yeniden denenebilir.

Baslik yazimi: WAL basligi bolgenin basina (offset `TailBase+G`) yazilir;
magic/CRC aynen korunur, boylece `Recover` mantigi degismez.

## 6. Gen bolgesi

`.gen` bugun `VDbOpenStreamNoFlock` ile ayri handle uzerinden aciliyor ve
**bayt aralik kilitleri** kullaniyor (`VDbLockGenReserve`).

Kritik tuzak: bolge `.odb` icine tasindiginda Linux'ta `flock` **butun
dosyayi** kilitler; gen kilidi ile veri kilidi ayni dosyada celisir ve
kendini kilitler. Bu yuzden v6'da gen kilidi **fcntl/POSIX byte-range**
(veya Windows `LockFileEx` aralik) olmak zorundadir:

- Windows: `LockFileEx` offset `TailBase*4096 + VDB_GEN_LOCK_OFF` (bugun
  zaten aralik kilidi kullaniyor; yalniz taban ofset eklenir).
- Unix: `flock` yerine `FpFcntl(F_SETLK)` aralik kilidi; ayni surecte iki
  farkli fd aralik kilidi celismez (POSIX kurali).

Bu, `VDbSync.pas` icinde yeni bir `VDbLockRangeAt(S, AOffset)` /
`VDbUnlockRangeAt` cifti demektir. v5 (yan dosya) yolu eski `flock`
davranisini korur.

## 7. Geri uyumluluk

| Dosya | Yazilabilir acilis | Salt-okunur acilis |
|---|---|---|
| v5 (bolgesiz) | ilk yazmada v6'ya yukseltilir (bolge yazilir) | eski yol, yan WAL ile kurtarma |
| v6 | bolgeli yol | bolgeli yol (kilitsiz) |
| v3/v4 | v6'ya yukseltilir (bolge eklenir) | eski yol |

`BACKUP TO` ciktisi: **v6 + bolgeler** yazilir; yedek tek basina acilir
(bolgeleri kendi icinde). Boyut bu yuzden buyur: en az rezerv kadar.

## 8. Kapi plani

| Kapi | Ne kanitlar |
|---|---|
| `single_file` (genisletme) | motor **acikken** dizinde tam 1 dosya; SF21+ |
| `wal_crash` (aynen) | bolge icindeki WAL ile cokme sonrasi kurtarma |
| `kv_wal` (aynen) | bolge WAL'i uzerinde ayni sozlesme |
| `backup_restore` | v6 yedek tek dosya, `VerifyBackup` |
| `page_integrity` | bolge tasima sonrasi sayfa butunlugu |
| yeni `region_stream` | `TVdbRegionStream` sinirlari: kapasite, Size, seek |
| yeni `tail_move` | blok tasima + yarim tasima (adim a/b arasi) simulasyonu |

Yarim tasima testi kritik: `SaveMeta` sirasinda kesip yeniden acildiginda
veritabaninin eski (gecerli) bloka donmesi gerekir.

## 9. Riskler

| # | Risk | Azaltma |
|---|---|---|
| V4-1 | Tek baslik kopyasi: page 0 torn write | Tasima adimlari fsync sirali; page 0 tek sayfa (4 KB) atomik yazim varsayimi. **Cifte baslik (page 0 + yedek) ayri is.** |
| V4-2 | Gen kilidi kendini kilitler (Linux flock) | v6'da aralik kilidi (fcntl); v5 yolu degismez |
| V4-3 | WAL bolgesi dolarsa commit kaybi | Islem reddedilir + rollback; bolge buyutme sonraki islem basinda |
| V4-4 | Bolge tasima ortasinda cokme | Eski blok gecerli kalir (adim c yazilmadan once) |
| V4-5 | Yedek boyutu buyur | Belgelenir; `VACUUM`/`BACKUP TO` rezervi guncel `FPageCount`'a gore yazar |
| V4-6 | v5 okuyucu v6 dosyayi acar mi | Evet: bolgeler veri sayfasi degil, `FPageCount` disinda; ama yazan bir v5 surumu bolgeleri ezer — belgeye "v6 dosyayi eski surumle yazma" uyarisi |

## 10. Uygulama sirasi (her adim ayri commit + kapi)

1. `VDbRegion.pas` + `tests/region_stream` (davranis kapisi).
2. Baslik alanlari + `RequiredFileSize`/`GrowTo` bolge farkindaligi
   (henuz bolge yazmadan; v5 davranisi degismez).
3. `TVdbPageWal` stream bicimi + `tests/wal_region`.
4. Gen bolgesi + aralik kilidi (`VDbSync` yeni API) + `tests/gen_region`.
5. Motor entegrasyonu: acilista bolge kur, kapanista **hicbir sey silme
   gerekmez** (tek dosya), tasima mantigi.
6. `single_file` SF21-SF24: acikken tam 1 dosya, cokme kurtarma, tasima.
7. Belgeler + `CHANGELOG` + `RC_REVIEW` §4 guncellemesi.

Bu sira, her adimda 19/18 kapinin yesil kalmasi kosuluyla ilerler.
