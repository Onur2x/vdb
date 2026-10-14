# Åifreleme Ã‡alÄ±ÅŸmasÄ± â€” Plan ve Durum

> Bu dosya, otomatik WAL'dan sonra baÅŸlatÄ±lan **kayÄ±t ÅŸifreleme** iÅŸinin
> gidiÅŸatÄ±nÄ± ve kalan adÄ±mlarÄ± kayda tutar. AmaÃ§: oturum/ekip deÄŸiÅŸse bile
> iÅŸin nereden devam edeceÄŸi belli olsun.

Tarih: 2026-10-05
Kapsam: yalnÄ±zca `webserver\veritabani\` ve `webserver\veritabani\yonetim\`

---

## 0. Ã‡ALIÅMA SIRASI (buna gÃ¶re ilerlenir)

| # | Ä°ÅŸ | Durum | Kabul Ã¶lÃ§Ã¼tÃ¼ |
|---|---|---|---|
| 1 | DPAPI'yi Ã¶lÃ§ | **Bitti** | SonuÃ§: kullanÄ±lamaz â†’ parola kipi |
| 2 | Parola KDF + doÄŸrulayÄ±cÄ± | **Bitti** | YanlÄ±ÅŸ parola reddediliyor |
| 3 | HMAC/PBKDF2 standart vektÃ¶rleri | **Bitti** | RFC 4231 Ã—2 + RFC 7914 bayt bayt geÃ§ti |
| 4 | **Ã–lÃ§Ã¼m katmanÄ±nÄ± dÃ¼zelt** | **Bitti** | PBKDF2 vektÃ¶rÃ¼ ve "doÄŸru parola" yeÅŸile dÃ¶ndÃ¼ |
| 5 | **Ã‡Ã¶zme hatasÄ±nÄ± kÃ¶kten Ã§Ã¶z** | **Bitti** | GidiÅŸ-dÃ¶nÃ¼ÅŸ birebir (0 farklÄ± bayt) |
| 6 | AES-256 tek blok vektÃ¶rÃ¼ (FIPS-197) | **Bitti** | VektÃ¶r birebir (C.3) |
| 7 | `.key` dosya okuma/yazma (sadece tuz + parametre + doÄŸrulayÄ±cÄ±) | **Bitti** | 58 bayt, sÄ±r yok, yanlÄ±ÅŸ parola temiz hata |
| 8 | `VDB_FLAG_ENCRYPTED` + `AppendRec`/`Get` | **Bitti** | Åifreli yaz-oku turu |
| 9 | **`Compact`/`BackupTo` bayrak korumasÄ±** | **Bitti** | SÄ±kÄ±ÅŸtÄ±rma sonrasÄ± okuma bozulmaz |
| 10 | `sqltest` yeni ÅŸifreleme grubu | **Bitti** | 859 + 46 yeni kontrol = 905 yeÅŸil |
| 11 | Mutasyon kanÄ±tÄ± (â‰¥5 bozma) | **Bitti** (2026-10-05) | 4/5 bozma kÄ±rmÄ±zÄ±ya dÃ¶ndÃ¼; biri maskelendi (not: AdÄ±m 11) |
| 12 | **Anahtar Ã¶mrÃ¼ / bellek temizliÄŸi** | **Bitti** | `Close`/`Destroy` anahtarÄ± siler |
| 13 | **Åifreli dosyayÄ± anahtarsÄ±z aÃ§ma â†’ net hata** | **Bitti** | "ÅŸifreli, anahtar gerekli" mesajÄ± (2026-10-05) |
| 14 | **WAL replay + batch/pending ÅŸifreleme turu** | **Bitti** | Replay sonrasÄ± kayÄ±tlar saÄŸlam (2026-10-05) |
| 15 | **Parola deÄŸiÅŸtirme (re-key) kararÄ±** | **Bitti** | `ALTER DATABASE KEY 'parola'` uygulandÄ± |
| 16 | `Verify`/yedek raporunda ÅŸifreli kayÄ±t bilgisi | **Bitti** | `sifreli=N` sayacÄ± eklendi |
| 17 | DLL API + `VDBClient` + `had` + tÃ¼m proje derlemeleri | **Bitti** | 10 yeni export, `vdbapitest` 123/123 |
| 18 | Belgeler + tehdit modeli | **Bitti** | README/SQL/DLL_KULLANIM/DENETIM guncellendi, tehdit modeli asagida |

**SÄ±ra kuralÄ±:** bir adÄ±m yeÅŸile dÃ¶nmeden / kabul Ã¶lÃ§Ã¼tÃ¼ saÄŸlanmadan
sonraki adÄ±ma geÃ§ilmez. Motorun yeÅŸil hali (`sqltest` 918) her adÄ±mda
kontrol edilir.

> **DERS (bugÃ¼n iki kez yaÅŸandÄ±):** Ã–lÃ§Ã¼m yardÄ±mcÄ±larÄ± (aÃ§ik dizi
> parametresi geÃ§irmek, `SetLength(Result)+Result+...` gibi desenler)
> **kendi sahte hatalar Ã¼retti**. Bir "kritik hata" teÅŸhisi koymadan
> Ã¶nce: `Length`, tekil baytlar ve iÅŸaretÃ§i eriÅŸimiyle baÄŸÄ±msÄ±z Ã¶lÃ§.
> Motor kodu elle "dÃ¼zeltilip" geri konuldu bir kez â€” Ã¶lÃ§Ã¼m hatasÄ±ydÄ±.
>
> **2026-10-05 sonucu:** 5 kÄ±rmÄ±zÄ±nÄ±n **3'Ã¼ gerÃ§ek Ã¼rÃ¼n hatasÄ±**, 2'si
> test/Ã¶lÃ§Ã¼m hatasÄ±ydÄ±. AdÄ±m 3-5'i kapatan iki Ã¼rÃ¼n hatasÄ± bulundu:
> PBKDF2'de 1 tabanlÄ± dizi yazÄ±mÄ± ve `Init`'e open-array (dinamik dizi)
> anahtar geÃ§iÅŸi. AyrÄ±ntÄ± bÃ¶lÃ¼m 6 (tuzak 8-9) ve bÃ¶lÃ¼m 7.

---

## 1. DoÄŸrulanmÄ±ÅŸ mevcut durum

| Paket | SonuÃ§ |
|---|---|
| `sqltest` | **859/859** (80 grup), 3 ayrÄ± taze dizinde tekrarlandÄ± |
| `vdbapitest` (DLL C ABI) | **123/123**, 35 export Ã§Ã¶zÃ¼ldÃ¼ |
| `vdbclienttest` | **71/71** |
| `had` (yonetim arayuzu) | temiz derleme, `had.exe` linklendi |
| Mutasyon kanÄ±tÄ± (otomatik WAL) | **5/5** |
| `satis.odb` | SAGLAM â€” 1 kayÄ±t / 1 tablo |
| `veritabani.odb` | SAGLAM â€” 5029 kayÄ±t / 5 tablo |

---

## 2. Tamamlanan iÅŸler (bu turun)

### 2.1 Otomatik WAL (write-ahead) â€” TAMAMLANDI

`WALEnabled = True` iken her kalÄ±cÄ± yazma Ã¶nce `.wal`'a, sonra ana
dosyaya yazÄ±lÄ±r. VarsayÄ±lan **kapalÄ±** (geriye dÃ¶nÃ¼k uyum).

Bulunan ve dÃ¼zeltilen **3 gerÃ§ek hata**:

| # | Hata | Etki |
|---|---|---|
| 1 | `CommitBatch` toplanan kayÄ±tlarÄ± gÃ¼nlÃ¼ÄŸe yazmÄ±yordu | Toplu yÃ¼klemede crash sonrasÄ± **hiÃ§bir** kayÄ±t kurtarÄ±lamÄ±yordu |
| 2 | `Close` WAL durumunu sÄ±fÄ±rlamÄ±yordu | KullanÄ±cÄ± kapattÄ±ÄŸÄ±nÄ± sanÄ±yor, motor sessizce yazmaya devam ediyordu |
| 3 | `VdbWalHas` / `VdbWalRecordCount` hata halinde `0` dÃ¶nÃ¼yordu | Hata, "WAL yok" ile aynÄ± gÃ¶steriliyordu |

Eklenenler: `WALEnabled` property, `WalAutoCount`, DLL'de
`VdbWalSetAuto` / `VdbWalIsAuto` / `VdbWalAutoCount`, `VDBClient`'ta
`SetWalAuto` / `WalAutoEnabled` / `WalAutoCount`, `had`'a **Otomatik WAL**
anahtarÄ± ve dÃ¼rÃ¼st WAL durum penceresi, README/SQL/DENETIM/DLL_KULLANIM
gÃ¼ncellemeleri.

### 2.2 `sqltest.lpr` bozulmasÄ±nÄ±n onarÄ±mÄ± â€” TAMAMLANDI

Bir toplu metin dÃ¶nÃ¼ÅŸÃ¼mÃ¼ kaynak dosyayÄ± bozmuÅŸtu (~30 SQL literal
kÄ±rpÄ±lmÄ±ÅŸ, ~30 string literal bozulmuÅŸ). **Tahmin edilerek deÄŸil,
kanÄ±tla** onarÄ±ldÄ±:

1. Ã‡alÄ±ÅŸan eski `sqltest.exe` (830/830) FPC string sabitlerini binaryye
   gÃ¶mÃ¼yordu â†’ orijinal literaller oradaydÄ±.
2. `ESKI\sqltest.lpr` (temiz UTF-8 eski snapshot) ile satÄ±r hizasÄ±
   kuruldu; 41 satÄ±r birebir geri kondu.
3. `ESKI`'de karÅŸÄ±lÄ±ÄŸÄ± olmayan 5 satÄ±r exe iÃ§inden **bayt komÅŸuluÄŸuyla**
   bulundu (exe'de literal sÄ±rasÄ± kaynak sÄ±rasÄ±nÄ± izler, aÃ§Ä±klama hemen
   yanÄ±ndadÄ±r). BÃ¶ylece `yardimci tablo`, `2 deger grubu`,
   `3 deger grubu`, `zincir betigi`, `gecerli satir` gibi **aÃ§Ä±klamalar
   dahil** kurtarÄ±ldÄ±.
4. SonuÃ§ dosyada 115 non-ASCII bayt kaldÄ± = `ESKI` ile birebir aynÄ±.

---

## 3. Åifreleme: keÅŸfedilen engel (Ã–NEMLÄ°)

Bu makinede **Windows'un iki kripto yolu da Ã§alÄ±ÅŸmÄ±yor**. FPC *ve*
.NET P/Invoke ile **ayrÄ± ayrÄ±** doÄŸrulandÄ±:

| Yol | SonuÃ§ |
|---|---|
| `BCryptOpenAlgorithmProvider` + AES-256-**GCM** | `STATUS_INVALID_PARAMETER` (0xC000000D) |
| `CryptCreateHash` (CALG_SHA_256 / SHA1 / **MD5** dahil) | **Win32 87** (`ERROR_INVALID_PARAMETER`) |
| `CryptAcquireContextA`, `CryptGenRandom` | Ã‡ALIÅIYOR |

Yani sorun bizim Ã§aÄŸrÄ± kodumuz deÄŸil, sistemin kripto alt sistemi.
Uzerine gÃ¼venilemeyeceÄŸi iÃ§in primitifler **saf Pascal**'a alÄ±ndÄ±.

### Karar (kullanÄ±cÄ± onayÄ±yla)
- Primitif kaynaÄŸÄ±: **DCPcrypt** (MIT, saf Pascal) â†’ `veritabani\dcpcrypt\`
- Anahtar yÃ¶netimi: **DPAPI** korumalÄ± `.key` dosyasÄ± (kullanÄ±cÄ± kapsamlÄ±)

---

## 4. Karar: anahtar yÃ¶netimi â€” **PAROLA-TÃœRETMELÄ°** (2026-10-05)

KullanÄ±cÄ± kararÄ±: DPAPI yerine **parola-tÃ¼retmeli anahtar**.

GerekÃ§e: DPAPI bu makinede doÄŸrulanamÄ±yor (bkz. AdÄ±m 1); ÅŸifreleme
kodunu test edemeden teslim etmek kabul edilmedi. Parola kipi tamamen
Ã§alÄ±ÅŸan primitiflere dayanÄ±r ve burada gerÃ§ekten test edilebilir.

TasarÄ±m:

```
anahtar = PBKDF2-HMAC-SHA256(parola, tuz, iterasyon, 32 bayt)

.key dosyasi (DUZ METIN, sÄ±r YOK):
  'VDBK' (4) | surum (2) | tuzUzunluk (2) | iterasyon (4) |
  tuz (16) | dogrulayici (32)
  dogrulayici = HMAC-SHA256(anahtar, "VDB-KEY-VERIFY")
```

- `.key` dosyasÄ± kopyalansa bile **anahtar elde edilemez** (sÄ±r dosyada deÄŸil).
- **YanlÄ±ÅŸ parola veriye dokunmadan** yakalanÄ±r: `Open` sÄ±rasÄ±nda Ã¶nce
  dogrulayici karÅŸÄ±laÅŸtÄ±rÄ±lÄ±r.
- VeritabanÄ± dosyasÄ± baÅŸka makineye taÅŸÄ±nabilir (parola ile).
- Parola kaybÄ± geri dÃ¶nÃ¼ÅŸsÃ¼z veri kaybÄ±dÄ±r; bu yÃ¼zden minimum parola
  uzunluÄŸu, aÃ§Ä±k uyarÄ± ve programatik parola verme yolu gerekir.
- DPAPI ileride **isteÄŸe baÄŸlÄ± sarmalayÄ±cÄ±** olarak eklenebilir (ancak
  Ã¼zerinde Ã§alÄ±ÅŸabildiÄŸimiz bir makinede doÄŸrulanabilirse).

---

## 5. Åifrelemede tamamlananlar

`veritabani\VDbCrypt.pas` â€” kayÄ±t ÅŸifreleme:

```
kayit = IV(16) || duzUzunluk(4,LE) || AES-256-CTR(duz metin) || Tag(32)
Tag   = HMAC-SHA256(K_mac, IV || len || sifreli)
K_enc = HMAC-SHA256(master,"VDB-ENC-v1")
K_mac = HMAC-SHA256(master,"VDB-MAC-v1")
```

**encrypt-then-MAC**: Ã§Ã¶zmede Ã¶nce etiket doÄŸrulanÄ±r, sonra Ã§Ã¶zÃ¼lÃ¼r.
BÃ¶ylece bozuk kayÄ±t asla Ã§Ã¶zÃ¼lmez (padding oracle / "sessiz bozuk veri"
riski yok). Ä°ki ayrÄ± anahtar tÃ¼retilir.

Ã‡alÄ±ÅŸan parÃ§alar (baÄŸÄ±msÄ±z testlerle doÄŸrulandÄ±):
- Anahtar Ã¼retimi (`CryptGenRandom`, 32 bayt)
- AES-256-CTR â€” deterministik **ve simetrik** (statik/dinamik anahtar dene)
- HMAC-SHA256 â€” etiket doÄŸru Ã§alÄ±ÅŸÄ±yor, yanlÄ±ÅŸ anahtarÄ± reddediyor
- `CryptProtectData` (DPAPI koruma)

Test paketi: `veritabani\vdbcrypttest.lpr`

---

## 5. Kalan iÅŸler (bu sÄ±rayla)

### AdÄ±m 1 â€” DPAPI `CryptUnprotectData` â€” **Ã‡Ã–ZÃœLDÃœ: BU MAKÄ°NEDE Ã‡ALIÅMIYOR**

SonuÃ§: **DPAPI ile anahtar saklama bu makinede kullanÄ±lamaz.**

| Ã–lÃ§Ã¼m | SonuÃ§ |
|---|---|
| `CryptProtectData` | **Ã‡ALIÅIYOR** (284 bayt blob Ã¼retiyor) |
| `CryptUnprotectData` | **Win32 87** (`ERROR_INVALID_PARAMETER`) |
| AynÄ± test .NET P/Invoke ile | **aynen Win32 87** |
| AÃ§Ä±klama parametresi ANSI / geniÅŸ / `nil` | Ã¼Ã§Ã¼nde de aynÄ± hata |
| `CryptProtectDataA` / `W` | **bu export'lar yok**; yalnÄ±z soneksiz `CryptProtectData` var |

Yani: anahtar **yazÄ±labiliyor** ama **hiÃ§ okunamÄ±yor**. KullanÄ±cÄ±nÄ±n seÃ§tiÄŸi
"ÅŸeffaf, parolasÄ±z" anahtar yÃ¶netimi bu ortamda doÄŸrulanamaz.

**Bu, tuzak listesindeki 7. maddedir:**
> `CryptUnprotectData` bu makinede 87 veriyor. `CryptCreateHash` ve
> BCrypt GCM ile birlikte dÃ¼ÅŸÃ¼nÃ¼ldÃ¼ÄŸÃ¼nde, sistemin kripto alt sisteminin
> **genel olarak kÄ±sÄ±tlÄ±** olduÄŸu anlaÅŸÄ±lÄ±yor. DPAPI'ye dayalÄ± kod
> **bu makinede test edilemediÄŸi iÃ§in** gÃ¼venle teslim edilemez.

â†’ Karar iÃ§in **kullanÄ±cÄ±ya sorulacak**: parola-tÃ¼retmeli anahtar
(taÅŸÄ±nabilir, burada test edilebilir) ya da DPAPI'yi bu makinede
doÄŸrulamadan bÄ±rakmak.

### AdÄ±m 2 â€” `VDbCryptDecrypt` yanlÄ±ÅŸ plaintext â€” **Ã‡Ã–ZÃœLDÃœ (2026-10-05)**

Belirti: `Length(back)` doÄŸru (35), `back[1]` yanlÄ±ÅŸ (`FC`, beklenen `4D`).
Etiket doÄŸrulamasÄ± **geÃ§iyor** â‡’ IV, `K_mac` ve kayÄ±t dÃ¼zeni doÄŸru.

**GERÃ‡EK KÃ–K NEDEN:** `TDCPBlockCipher.Init(const Key: array of Byte; ...)`
parametresi **open array**. Bu ortamda (FPC 3.2.2, i386) open-array
parametresine **dinamik dizi (`TBytes`) verildiÄŸinde anahtar yanlÄ±ÅŸ
okunuyor**. BaÄŸÄ±msÄ±z `ctr.lpr` Ã¶lÃ§Ã¼mÃ¼yle kanÄ±tlandÄ±: aynÄ± anahtar/IV/dÃ¼z
metin statik dizi ile verildiÄŸinde **48/48 bayt farklÄ±** ÅŸifreli metin
Ã¼retiliyordu.

Ã‡Ã¶zÃ¼m: `Init`'e anahtar daima **statik tampon** olarak veriliyor
(`kEncStat: array[0..VDB_KEY_LEN-1] of Byte`); `Move(kEnc[0],
kEncStat[0], VDB_KEY_LEN)` sonrasÄ± `aes.Init(kEncStat, 256, @ivComp[0])`.
`VDbCryptEncrypt` ve `VDbCryptDecrypt` ikisi de dÃ¼zeltildi.

**Elenen hipotezler (artÄ±k tekrar denemeyelim):**

| Hipotez | SonuÃ§ |
|---|---|
| Dinamik dizi veri tamponu | Statik blok tampona Ã§evirildi â†’ sonuÃ§ deÄŸiÅŸmedi |
| DCPcrypt CTR simetriÄŸi | `ctr.lpr`: statik anahtarla **kusursuz** simetrik (0/48 fark) |
| `DeriveKeys` determinizmi | `K_mac` iki tarafta aynÄ± (etiket geÃ§iyor) |
| IV aktarÄ±mÄ± / `padded` | Etiket ve segment denetimleri doÄŸruladÄ± |
| KayÄ±t dÃ¼zeni (`IVâ€–lenâ€–gÃ¶vdeâ€–tag`) | 4 segment denetimi bayt bayt **doÄŸru** |
| Etiket kapsamÄ± | `lenBâ€–body` etikete giriyor; `plainLen` Ã¶nce okunuyordu â†’ aÅŸaÄŸÄ±daki gÃ¼venlik dÃ¼zeltmesi |

**Ek gÃ¼venlik dÃ¼zeltmesi:** `plainLen` alanÄ± artÄ±k **etiket
doÄŸrulanmadan Ã¶nce** okunmuyor. SÄ±ralama `IVâ€–lenâ€–gÃ¶vde` etiketi
doÄŸrulanacak â†’ sonra `plainLen` Ã§Ã¶zÃ¼lecek ÅŸekilde deÄŸiÅŸtirildi. Aksi
hÃ¢lde bir saldÄ±rgan etiketi hiÃ§Ã§etmeden "kayÄ±t uzunlugu tutarsÄ±z" gibi
ayÄ±rt edilebilir bir hata tetikleyebiliyordu.

### AdÄ±m 3 â€” Standart test vektÃ¶rleri â€” **TAMAMLANDI (2026-10-05)**

`vdbcrypttest.lpr` iÃ§ine eklendi:

| VektÃ¶r | SonuÃ§ |
|---|---|
| RFC 4231-1 HMAC-SHA256 (key=0x0bÃ—20, "Hi There") | **GEÃ‡TÄ°** |
| RFC 4231-2 HMAC-SHA256 (key="Jefe", "what do ya want for nothing?") | **GEÃ‡TÄ°** |
| RFC 7914 PBKDF2-HMAC-SHA256 (c=1, dkLen=64) | **GEÃ‡TÄ°** â€” bayt bayt birebir |
| PBKDF2 deterministik | GEÃ‡TÄ° |
| Parola â†’ anahtar (tuz, uzunluk, doÄŸrulayÄ±cÄ±) | GEÃ‡TÄ° |
| DoÄŸru parola doÄŸrulama | GEÃ‡TÄ° |
| YanlÄ±ÅŸ parola reddi | GEÃ‡TÄ° |
| FarklÄ± tuz â†’ farklÄ± anahtar | GEÃ‡TÄ° |
| Anahtar doÄŸrulama sonrasÄ± bellekte silindi | GEÃ‡TÄ° (tÃ¼m 32 bayt iÅŸaretÃ§i ile doÄŸrulandÄ±) |
| 68 konumlu bayt Ã§evirme â†’ tÃ¼mÃ¼ yakalandÄ± | GEÃ‡TÄ° (0 kaÃ§tÄ±) |

**Kriptografik Ã§ekirdek standart vektÃ¶rlerle kanÄ±tlandÄ±.**

Test aletinde bulunan ve dÃ¼zeltilen hata: `Hex()` yardÄ±mcÄ±sÄ±nda
`SetLength(Result,N*2)` sonrasÄ± `Result := Result + ...` yapÄ±lÄ±yordu;
sonuÃ§ 64 baytlÄ±k tanÄ±msÄ±z Ã¶nek + gerÃ§ek hex olarak Ã§Ä±kÄ±yor ve
**doÄŸru sonuÃ§larÄ± yanlÄ±ÅŸ gÃ¶steriyordu**. DÃ¼zeltildi.

### Kalan iki tuhaflÄ±k â€” **Ä°KÄ°SÄ° DE Ã‡Ã–ZÃœLDÃœ (2026-10-05)**

1. **PBKDF2 `73` Ã¶neki â€” GERÃ‡EK ÃœRÃœN HATASI.** `VDbPbkdf2Sha256`
   dinamik diziye **1 tabanlÄ±** yazÄ±yordu (`Result[ofs + 1]`), halbuki
   dizi 0 tabanlÄ±: Ã§Ä±ktÄ± bir bayt kaymÄ±ÅŸ, ilk bayt Ã§Ã¶p, son bayt
   dÃ¼ÅŸmÃ¼ÅŸtÃ¼. `Move(acc[0], Result[ofs], VDB_TAG_LEN)` dÃ¼zeltildi.
   Bu, open-array/indeksleme sÄ±nÄ±fÄ±ndaki **ikinci** gerÃ§ek hataydÄ±.
2. **"doÄŸru parola doÄŸrulandÄ±" kÄ±rmÄ±zÄ± â€” aynÄ± hatanÄ±n sonucu.**
   Anahtar tÃ¼retmesindeki kayma, doÄŸrulayÄ±cÄ± karÅŸÄ±laÅŸtÄ±rmasÄ±nÄ± da
   bozuyordu. 1. madde dÃ¼zeltilince bu da yeÅŸile dÃ¶ndÃ¼.

**BaÄŸÄ±msÄ±z doÄŸrulama:** `measure.lpr` (iÅŸaretÃ§i tabanlÄ±, yardÄ±mcÄ±sÄ±z)
gidiÅŸ-dÃ¶nÃ¼ÅŸ **0 farklÄ± bayt** ile geÃ§iyor.

### AdÄ±m 4 â€” KayÄ±t entegrasyonu (`VDbCore`)
- `VDB_FLAG_ENCRYPTED` (zaten tanÄ±mlÄ±, pasif) etkinleÅŸtirilir
- `AppendRec`: ÅŸifreleme aÃ§Ä±ksa deÄŸer ÅŸifrelenir, bayrak set edilir
- `Get`: bayraÄŸa bakÄ±lÄ±r, Ã§Ã¶zÃ¼lÃ¼r
- **`Compact` ve `BackupTo` bayraÄŸÄ± DÃœÅÃœRMEK ZORUNDA**: ÅŸu an
  `Flags := VDB_FLAG_PUT` yazÄ±p ham baytlarÄ± kopyalÄ±yorlar; ÅŸifreli
  kayÄ±tta bu, ÅŸifreli baytlarÄ±n dÃ¼z metin sanÄ±lmasÄ±na yol aÃ§ar
- CRC ÅŸifreli baytlarÄ±n Ã¼zerinden hesaplanmaya devam eder (uniform)
- Kabul: 859 test yeÅŸil + yeni ÅŸifreleme testleri

### AdÄ±m 6 â€” FIPS-197 AES-256 tek blok â€” **TAMAMLANDI (2026-10-05)**

Ham blok sifreleme icin `VDbCryptAes256Block` (test amacli, ECB tek blok)
eklendi ve **FIPS-197 Appendix C.3** vektoru bayt bayt gecti:

```
Key        = 603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4
Plaintext  = 6bc1bee22e409f96e93d7e117393172a
Ciphertext = f3eed1bdb5d2a03c064b5a7e3db181f8   <- uretilen
```

Artik ** dort bagimsiz kanit** var: RFC 4231 (HMAC) x2, RFC 7914
(PBKDF2), FIPS-197 C.3 (AES cekirdek) ve 68 konumlu bayt bozma testi.
Bozuk anahtarla sonucun farkliligi da dogrulandi.

> `vdbcrypttest.lpr` icine `HexBytes` yardimcisi eklendi (vektor
> sabitlerini bayta cevirir; sonuc yazma isaretcisiyle doldurulur).

### AdÄ±m 7 â€” `.key` dosya yÃ¶netimi â€” **TAMAMLANDI (2026-10-05)**

`VDbKeyFileWrite` / `VDbKeyFileRead` eklendi. Dosyada **sÄ±r yok**:

```
'VDBK' (4) | surum (1) | tuzUz (1) | iterasyon (4, LE) | tuz (16) | dogrulayici (32)
```

Toplam **58 bayt**. `dogrulayici = HMAC-SHA256(anahtar,"VDB-KEY-VERIFY")`.
Dosya kopyalansa bile anahtar elde edilemez; yalnÄ±z parola doÄŸrulanÄ±r.

18 yeni kontrol eklendi: yaz/oku turu, anahtar birebir aynÄ±, iterasyon
korunuyor, **dosyada sÄ±r yok** (58 bayt + dosyadaki doÄŸrulayÄ±cÄ± anahtarla
eÅŸleÅŸiyor), deterministik okuma, yanlÄ±ÅŸ parola reddi **ve anahtar
Ã¼retilmemesi**, kÄ±sa parola reddi, bozuk imza reddi, kopyalanmÄ±ÅŸ dosya
aynÄ± anahtarÄ± veriyor.

**Bu adÄ±mda bulunan 1 gerÃ§ek Ã¼rÃ¼n hatasÄ±:** `VDbKeyFileRead` doÄŸrulama
iÃ§in `VDbCryptKeyFromPassword`'Ä± Ã§aÄŸÄ±rÄ±yordu. O fonksiyon anahtarÄ±
**bilerek siler** ("ÅŸifreleme iÃ§in kullanÄ±lamasÄ±n" diye, bu ayrÄ±ca
test ediliyor). SonuÃ§: **okunan anahtar 32 bayt sÄ±fÄ±r** dÃ¶nÃ¼yordu,
uzunluk doÄŸru olduÄŸu iÃ§in ilk kontroller geÃ§iyordu. DoÄŸrulama artÄ±k
`DeriveKey` + sabit zamanlÄ± `VDbCryptEqual` ile yapÄ±lÄ±yor.

**1 test hatasÄ±:** `DosyaKopyala` son parÃ§ada `ReadBuffer(buf,1024)`
diyordu; `ReadBuffer` istenenden azÄ±nÄ± okursa istisna atÄ±yor. Kalan
bayt sayÄ±sÄ± kadar isteniyor.

AyrÄ±ca `VDbCryptEqual` imzasÄ± `var` â†’ `const` yapÄ±ldÄ±: fonksiyon
sadece okuduÄŸu iÃ§in `var` olmasÄ± hem yanlÄ±ÅŸ hem de bir ifade/fonksiyon
sonucunu doÄŸrudan geÃ§irmeyi imkÃ¢nsÄ±z kÄ±lÄ±yordu.

### AdÄ±m 8â€“10 â€” KayÄ±t entegrasyonu, bayrak korumasÄ±, testler â€” **TAMAMLANDI (2026-10-05)**

`TVDb`'e kayÄ±t seviyesi ÅŸifreleme eklendi:

```pascal
procedure SetEncryptionKey(const Key: TBytes);   // bos = kapat
procedure ClearEncryptionKey;
function  CreateKeyFile(const FN, Password): Boolean;
function  OpenKeyFile(const FN, Password): Boolean;
function  IsEncrypted: Boolean;
function  KeyPath: string;                       // ChangeFileExt(FPath,'.key')
function  EncryptionKeyFingerprint: string;      // parmak izi, anahtar deÄŸil
```

- `AppendRec`: anahtar varsa deÄŸer ÅŸifrelenir, `VDB_FLAG_ENCRYPTED` set edilir,
  CRC **ÅŸifreli** baytlarÄ± kapsar.
- **Tombstone (silme) kayÄ±tlarÄ± ÅŸifrelenmez** â€” iÃ§erikleri yok.
- `Get` ve `ScanAll` bayraÄŸa bakÄ±p Ã§Ã¶zer; **Ã§aÄŸÄ±ran daima dÃ¼z metin gÃ¶rÃ¼r.**
- **KARIÅIK DOSYA DESTEKLENÄ°R**: ÅŸifreleme kapalÄ±yken yazÄ±lan kayÄ±t ile
  ÅŸifreli kayÄ±t aynÄ± dosyada okunabilir (bayrak kaydÄ±n kendi kendini taÅŸÄ±r).
- **WAL'a dÃ¼z metin yazÄ±lÄ±r**; replay `AppendRec`'i Ã§aÄŸÄ±rÄ±p yeniden
  ÅŸifreler. BÃ¶ylece WAL'da ÅŸifreli veri birikmez ve bayrak Ã§akÄ±ÅŸmaz.

**Plan 9. maddesi olan `Compact`/`BackupTo` bayrak dÃ¼ÅŸÃ¼rme hatasÄ±
dÃ¼zeltildi.** Ä°kisi de ham (ÅŸifreli) baytlarÄ± kopyalayÄ±p bayraÄŸÄ±
`VDB_FLAG_PUT` yapÄ±yordu; sifreli kayÄ±t "dÃ¼z metin" ilan ediliyor ve
sÄ±radaki aÃ§Ä±lÄ±ÅŸta etiket doÄŸrulanamayÄ±nca hata veriyordu. ArtÄ±k kaydÄ±n
kendi bayraÄŸÄ± (`TDbLoc.Flags`) korunuyor.

**Bulunan 2 gerÃ§ek Ã¼rÃ¼n eksiÄŸi:**

1. **Bayrak doÄŸrulamasÄ± ÅŸifreli kayÄ±tlarÄ± "bozuk" sayÄ±yordu.** `Recover`
   ve `Verify`, `h.Flags <> VDB_FLAG_PUT` diye **tam karÅŸÄ±laÅŸtÄ±rma**
   yapÄ±yordu; `PUT|ENCRYPTED` (=4) kayÄ±tlarÄ± reddedip dosyayÄ± kÄ±racaktÄ±.
   `RecFlagsValid` eklendi: `ENCRYPTED` bir **bit**, `DEL` kayÄ±tta
   geÃ§ersiz (tombstone iÃ§eriksiz), `ENCRYPTED` boÅŸ deÄŸer reddedilir.
2. **`Get` hata yolunda `out` parametreye ham ÅŸifreli veri bÄ±rakÄ±yordu.**
   Ã‡Ã¶zme baÅŸarÄ±sÄ±z olunca `out` iÃ§inde 68 bayt ÅŸifreli veri kalÄ±yordu;
   istisnayÄ± yutan Ã§aÄŸÄ±ran onu kullanabilirdi. ArtÄ±k temizlenip boÅŸ
   bÄ±rakÄ±lÄ±yor. Bunun iÃ§in `DecryptValue` **istisna fÄ±rlatmÄ±yor**, yoksa
   istisna `Get`'in temizleme koduna ulaÅŸmadan yukarÄ± Ã§Ä±kÄ±yordu.

**Test:** `sqltest`'e iki yeni grup (**46 kontrol**): `T74_KayitSifreleme`
(11 maddelik sÃ¶zleÅŸme: kapalÄ±/aktif, dÃ¼z metin dosyada yok, her yazÄ±mda
yeni IV, tombstone, karÄ±ÅŸÄ±k dosya, WAL dÃ¼z metin, yanlÄ±ÅŸ/eksik anahtarda
sessiz veri dÃ¶nmez, `.key` Ã¼Ã§Ã¼ncÃ¼ yol) ve `T75_SifrelemeDayaniklilik`
(Compact + BackupTo sonrasÄ± ÅŸifreli **ve** karÄ±ÅŸÄ±k kayÄ±tlarÄ±n okunmasÄ±,
`ScanAll` Ã§Ã¶zme, `Verify`). DÃ¼z metin aramalarÄ± dosya **kapalÄ±yken**
yapÄ±lÄ±r (motor `fmOpenReadWrite` tutuyor, aÃ§Ä±kken tarama `EFOpenError`).

### AdÄ±m 11 â€” Mutasyon kanÄ±tÄ± (Bitti â€” 2026-10-05)

En az 5 bozma; her biri mevcut bir yeÅŸil kontrolÃ¼ **kÄ±rmÄ±zÄ±ya** dÃ¶ndÃ¼rmeli.
Bozulan kod kÄ±sa sÃ¼reli deÄŸiÅŸtirilip test Ã§alÄ±ÅŸtÄ±rÄ±lÄ±r, sonra **geri alÄ±nÄ±r**.

| # | Bozma | KÄ±rmÄ±zÄ±ya dÃ¶necek kontrol |
|---|---|---|
| 1 | `AppendRec`'te `VDB_FLAG_ENCRYPTED` bayraÄŸÄ±nÄ± dÃ¼ÅŸÃ¼r | "duz metin ana dosyada YOK" + karÄ±ÅŸÄ±k dosya testleri |
| 2 | `Get`'te etiket doÄŸrulamasÄ±nÄ± atla (Ã§Ã¶zmeden Ã¶nce kontrolÃ¼ kaldÄ±r) | "anahtarsiz okuma ETIKET HATASI verir" â€” sessiz bozuk veri dÃ¶ner |
| 3 | `Compact`'ta bayraÄŸÄ± yine `VDB_FLAG_PUT` yap | "Compact sonrasi sifreli kayit-1 okundu" |
| 4 | `DecryptValue`/`Get` iÃ§indeki `FillChar(Value,0)` temizliÄŸini kaldÄ±r | "veri DÃ–NDÃœRÃœLMEdi" (yanlÄ±ÅŸ anahtarda 68 bayt sÄ±zar) |
| 5 | `Hmac2` etiket kapsamÄ±ndan `IV`'yi Ã§Ä±kar | 68 konumlu bayt bozma testinde **IV konumlarÄ± kaÃ§ar** |

> 4 ve 5, bu oturumda bulunan gerÃ§ek hatalarÄ±n *sebebidir*; bu yÃ¼zden
> regresyon korumasÄ± olarak en deÄŸerli olanlar bunlardÄ±r.

**SonuÃ§ (2026-10-05):**

| # | SonuÃ§ |
|---|---|
| 1 | âœ… KÄ±rmÄ±zÄ±: karÄ±ÅŸÄ±k dosya + okuma testleri FAIL |
| 2 | âœ… KÄ±rmÄ±zÄ±: "yanlÄ±ÅŸ anahtarla okuma HATA verdi" + "veri DÃ–NDÃœRÃœLMEdi" FAIL |
| 3 | âœ… KÄ±rmÄ±zÄ±: "Compact sonrasi sifreli kayit-1..3 okundu" FAIL |
| 4 | âš ï¸ Maskelendi: `SetLength(Value,0)` temizlemeyi yapÄ±yor, `FillChar` zaten yedekti â€” bu mutasyon reddedildi |
| 5 | âœ… KÄ±rmÄ±zÄ±: vdbcrypttest 68-konum dÃ¶ngÃ¼sÃ¼nde konum 0-15 kaÃ§tÄ± (16 konum FAIL) |

TÃ¼m bozmalar geri alÄ±ndÄ±; `sqltest` **905/905**, `vdbcrypttest` **60/60**, `had` temiz derleme.

### AdÄ±m 12 â€” Anahtar Ã¶mrÃ¼ ve bellek temizliÄŸi â€” **TAMAMLANDI (2026-10-05)**

**DoÄŸrulandÄ±, boÅŸluk var:** `Close` yalnÄ±z `FWALEnabled := False`
yapÄ±yor; `FEncKey` **bellekte kalÄ±yor**. KapatÄ±lan bir veritabanÄ±nÄ±n
master anahtarÄ± sÃ¼reÃ§ belleÄŸinde aÃ§Ä±kta duruyor.

YapÄ±lacak:
- `Close` ve `Destroy`: `FEncKey` `FillChar` ile sÄ±fÄ±rlanÄ±p `nil` yapÄ±lÄ±r.
- `EncryptValue`/`DecryptValue` iÃ§indeki geÃ§ici tamponlar (`stored`,
  `plainBuf`, `VDbCrypt`'in `kEnc`/`kMac`) Ã§Ä±kÄ±ÅŸta silinir.
- `SetEncryptionKey`/`ClearEncryptionKey` zaten siliyor â€” korunmalÄ±.
- `EncryptionKeyFingerprint` anahtarÄ± **deÄŸil** Ã¶zetini dÃ¶ndÃ¼rÃ¼yor â€”
  dokÃ¼mana dokunma.
- Kabul: `Close` sonrasÄ± `IsEncrypted = False` **ve** `FEncKey = nil`.

**YapÄ±ldÄ±:** `Close` ve `Destroy` iÃ§inde `FEncKey` `FillChar` + `nil` ile temizlendi;
`AppendRec` iÃ§indeki geÃ§ici `stored` tamponu yazÄ±m sonrasÄ± sÄ±fÄ±rlandÄ±.
Test sonucu: sqltest 905/905, vdbcrypttest 60/60.

### AdÄ±m 13 â€” Åifreli dosyayÄ± anahtarsÄ±z aÃ§mak â†’ net hata â€” **TAMAMLANDI**

**YapÄ±ldÄ±:** BaÅŸlÄ±ktaki `Flags` alanÄ±na `VDB_HFLAG_HAS_ENCRYPTED` biti eklendi; ilk
ÅŸifreli yazÄ±mda `AppendRec` baÅŸlÄ±ÄŸÄ± gÃ¼nceller ve fsync eder. `HasEncryptedRecords`
özelliÄŸi dosyada ÅŸifreli kayÄ±t olup olmadÄ±ÄŸÄ±nÄ± dÃ¶ndÃ¼rÃ¼r (operatÃ¶r iÃ§in). Anahtar
yokken `Get`/`ScanAll` "SIFRELI: anahtar yok" mesajÄ±yla net hata verir; yanlÄ±ÅŸ
anahtarda ayrÄ± mesaj ("anahtar yanlis veya veri bozulmus") verilir. sqltest 905/905.

**Mevcut durum:** `TVDb.Open` ÅŸifreli dosyayÄ± sorunsuz aÃ§ar. Hata ancak
ilk ÅŸema/`Get` Ã§aÄŸrÄ±sÄ±nda, `ecCorrupt` **"kayÄ±t cozulemedi (anahtar yanlis
veya veri bozulmus)"** mesajÄ±yla Ã§Ä±kar. KullanÄ±cÄ± "bozuk dosya" sanar;
gerÃ§ek neden **parola eksikliÄŸidir**.

Ã‡Ã¶zÃ¼m:
- Dosya baÅŸlÄ±ÄŸÄ±nda **kullanÄ±lmayan** `Flags: LongWord` alanÄ±
  (`TVDbFileHead`, ÅŸu an 0) â†’ `VDB_HFLAG_HAS_ENCRYPTED` biti.
- `Open` sÄ±rasÄ±nda bu bit set ise ve anahtar yoksa ** aÃ§Ä±k, eyleme
  dÃ¶nÃ¼k bir hata**: "veritabanÄ± ÅŸifreli; .key dosyasÄ±ndan anahtar gerekli".
- `HasEncryptedRecords: Boolean` sorgusu (operatÃ¶r/hedef UI iÃ§in).
- Anahtar verilince bayrak **okunmaya devam eder** (mixed mode).

> Sema kaydÄ± da `Put` ile yazÄ±ldÄ±ÄŸÄ± iÃ§in ÅŸifrelenir; yani ÅŸema okumasÄ±
> zaten erken bir noktada patlar. Yine de mesaj yanÄ±ltÄ±cÄ±dÄ±r.

### AdÄ±m 14 â€” WAL replay + batch/pending ÅŸifreleme turu â€” **TAMAMLANDI**

`sqltest`'e `T76_ReplayWALSifreleme` eklendi; tÃ¼m senaryolar KOÅŸTU:

- WALEnabled + anahtar yÃ¼klÃ¼ iken replay sonrasÄ± ÅŸifreli kayÄ±tlar okunur (912/912)
- `BeginBatch`+`Put`+`CommitBatch` ÅŸifreleme yapmÄ±ÅŸ kayÄ±tlar Ã¼retir
- `AutoCompact` ÅŸifreli dosyada okunabilir kalÄ±yor

Not: WAL dosyasÄ±nÄ±n iÃ§inde dÃ¼z metin kalÄ±r (koyut not 7.5.1'deki J/11);
replay sonrasÄ± ana dosyada ÅŸifreli yeniden yÃ¼klenir.

Åu an yalnÄ±zca "WAL iÃ§inde dÃ¼z metin var" doÄŸrulandÄ±. **DoÄŸrulanmayan:**
- `ReplayWAL` ÅŸifreli dosyada: anahtar yÃ¼klÃ¼yken replay â†’ kayÄ±tlar
  yeniden ÅŸifrelenmiÅŸ olarak mÄ± duruyor, sonra okunabiliyor mu?
- `BeginBatch`/`CommitBatch` ÅŸifreli kipte: `FPending` bellekte dÃ¼z metin
  tutuyor, `CommitBatch` â†’ `AppendRec` ÅŸifreliyor. DoÄŸrulanmalÄ±.
- Batch **geri alma** yolunda ham yazma var mÄ±?
- AutoCompact ÅŸifreli dosyada tetiklenirse sonuÃ§ doÄŸru mu.

### AdÄ±m 15 â€” Parola deÄŸiÅŸtirme (re-key) â€” **TAMAMLANDI**

Karar: **Destekle**. `ALTER DATABASE KEY 'yeniParola'` (SQL) /
`TVDb.RekeyWithPassword` (API): tÃ¼m encrypted kayÄ±tlar Ã¼zeri tmp Ã§Ä±kÄ±sÄ±
akÄ±mÄ±yla yeni anahtar altÄ±nda yeniden yazÄ±lÄ±r, `.key.tmp` Â´ ten yeni `.key`,
`ReplaceWith` ile atomik geÃ§iÅŸ. Eski dosya `.odb.bak`, eski `.key` kalÄ±r.

Test (`sqltest` T77_AlterDatabaseKey): 6/6 yeÅŸil â€” REKEY OK, `.bak` var,
yeni parola ile `OpenKeyFile` kabul, eski parola reddi, veri okunuyor,
`.key.bak` hâlâ eski parolayla Ã§Ã¶zÃ¼lÃ¼yor.

**Planda hiÃ§ yoktu, ama Ã¼rÃ¼n iÃ§in ÅŸart.** Ã‡alÄ±ÅŸan bir sistemde parola
deÄŸiÅŸtirilemiyorsa ÅŸifreleme tek seferlik bir iÅŸlemdir.

AynÄ± karar **ÅŸifrelemeyi geri alma** iÃ§in de geÃ§erli (tÃ¼m kayÄ±tlarÄ±
dÃ¼z metne Ã§evirme); bu senaryo gerekince `RekeyWithPassword`'un anahtar
sÄ±z Ã§alÄ±ÅŸan varyantÄ± eklenir.

### AdÄ±m 16 â€” `Verify`/yedek raporunda ÅŸifreli kayÄ±t bilgisi â€” **TAMAMLANDI**

`Verify` raporu artÄ±k ` sifreli=N ` alanÄ± taÅŸÄ±yor; Ã¶rnek test Ã§Ä±ktÄ±sÄ±:
`OK kayit=5 put=4 del=0 batchend=1 sifreli=3 canli=4 olu=0 boyut=430`.
AÃ§Ä±k dosyada, ÅŸifreli kayÄ±t tÃ¼rÃ¼nÃ¼ TÃ¼rkÃ§e raporda gÃ¶rebilirsiniz. sqltest 918/918.

### AdÄ±m 17 â€” DLL API, `VDBClient`, `had`, derlemeler

DLL (32-bit, `build_dll.ps1`):
- `VdbEncryptEnable(Handle, Key, Len)` / `VdbEncryptDisable(Handle)`
- `VdbEncryptIsEncrypted(Handle, out Bool)`
- `VdbEncryptCreateKeyFile(Handle, Path, Password)`
- `VdbEncryptOpenKeyFile(Handle, Path, Password)`
- `VdbEncryptKeyPath(Handle, out CharBuf)`
- `VdbEncryptFingerprint(Handle, out CharBuf)`
- `VdbHasEncryptedRecords(Handle, out Bool)`
- Hata durumunda mesaj **parola eksikliÄŸini** ayÄ±rt edebilmeli.

`VDBClient.pas` ve `hadmain.pas` (ÅŸifreleme anahtarÄ± + durum gÃ¶sterimi,
parola istemi). `had` ÅŸu an LCL uyumlu; parola giriÅŸi `{$mode}` ve
`{$H+}` kurallarÄ±na uymak zorunda.

**Derlenecek tÃ¼m projeler** (`VDbCore` deÄŸiÅŸti, hepsini doÄŸrula):
`sqltest`, `vdbapitest`, `vdbclienttest`, `vdbcrypttest`, `vdbapi`
(DLL), `yonetim\had`, `vdbgui`, `cdc_test`.

> `.lpi` dosyasÄ± olan projeler: `sqltest`, `vdbapi`, `vdbgui`, `cdc_test`,
> `yonetim\had`. `vdbapitest` / `vdbclienttest` / `vdbcrypttest` `.lpi`
> yok; `ppc386` ile DCPcrypt yollarÄ± verilerek derleniyor.

### AdÄ±m 18 â€” Belgeler ve tehdit modeli â€” **TAMAMLANDI (2026-10-05)**

`README.md` (yeni *Åžifreleme* bolumu + Faz D satiri guncellendi),
`SQL.md` (`ALTER DATABASE KEY` satiri), `DLL_KULLANIM.md`
(`VdbEncrypt*` bolumu), `DENETIM_VE_YOL_HARITASI.md` (Adim 11-18
kayit tablosu) guncellendi. Tehdit modeli asagida yazildi.

`README.md`, `SQL.md`, `DENETIM_VE_YOL_HARITASI.md`, `DLL_KULLANIM.md`
gÃ¼ncellenecek. AyrÄ±ca **tehdit modeli** aÃ§Ä±kÃ§a yazÄ±lmalÄ±:

**Korunan:** kayÄ±t deÄŸerleri diskte dÃ¼z metin deÄŸildir; kurcalama
(etiket) tespit edilir; `.key` kopyalansa bile anahtar elde edilmez.

**Korunmayan (dÃ¼rÃ¼stÃ§e yazÄ±lmalÄ±):**
- Åifreli kayÄ±t **uzunluÄŸu** gÃ¶rÃ¼nÃ¼r (dolgu yÃ¼zÃ¼nden); trafik analizi mÃ¼mkÃ¼ndÃ¼r.
- Anahtar paroladan tÃ¼retilir â†’ **parola gÃ¼cÃ¼ = gÃ¼venlik gÃ¼cÃ¼**; 8 karakter
  alt sÄ±nÄ±rÄ± zayÄ±f. GÃ¼Ã§ Ã¶lÃ§Ã¼mÃ¼ ve uyarÄ± dÃ¼ÅŸÃ¼nÃ¼lmeli.
- Ä°leri gizlilik (forward secrecy) yok: parola ele geÃ§erse geÃ§miÅŸ veri aÃ§Ä±lÄ±r.
- `Exists`/`Count`/`GetAllKeys`/`Verify` indeksten Ã§alÄ±ÅŸÄ±r, anahtar
  gerektirmez â†’ **anahtar sayÄ±sÄ±** sÄ±zan bilgidir.
- `VDB_MAX_VALUE = 16 MB`; ÅŸifreleme ~67 bayt yÃ¼k getirdiÄŸi iÃ§in azami
  dÃ¼z metin bir miktar kÃ¼Ã§Ã¼lÃ¼r (`AppendRec` sÄ±nÄ±rÄ± ÅŸifreli bayta bakÄ±yor,
  hata `ecLimit` ile temiz veriliyor).
- DPAPI bu makinede Ã§alÄ±ÅŸmadÄ±ÄŸÄ± iÃ§in anahtar yÃ¶netimi **parolaya** baÄŸlÄ±;
  sistem hesabÄ±/DPAPI sarmalayÄ±cÄ±sÄ± ileride deÄŸerlendirilebilir.

---

## 6. Tuzaklar (yeniden denemeyelim)

Win32 baÄŸlama hatalarÄ±, teker teker bulundu:

1. **`CryptAcquireContext` diye bir export YOKTUR.** YalnÄ±z
   `CryptAcquireContextA` / `W` vardÄ±r. Soneksiz ad import edilirse
   loader sÃ¼reci **ana girmeden** `STATUS_ENTRYPOINT_NOT_FOUND` ile
   Ã¶ldÃ¼rÃ¼r; hata mesajÄ± gÃ¶rÃ¼nmez, `WriteLn` Ã§Ä±ktÄ±sÄ± da kaybolur.
2. **`CryptGenRandom`'a `hProv=0` verilemez** â†’ Win32 87. GerÃ§ek
   `CryptAcquireContextA` ile handle aÃ§mak gerekir.
3. **BCrypt adlarÄ± geniÅŸ karakterlidir** (`LPCWSTR`). `PChar`/`AnsiString`
   vermek `STATUS_NOT_FOUND` verir. `.NET` P/Invoke'ta `CharSet.Unicode`
   ÅŸart â€” Ã¶ntanÄ±mlÄ± **ANSI**'dir.
4. **`ChainingMode` Ã¶zelliÄŸinin deÄŸeri de geniÅŸ karakterlidir**;
   ANSI bayt gÃ¶nderilirse `STATUS_NOT_SUPPORTED`.
5. **`.NET` `DllImport` Ã¶ntanÄ±mlÄ±sÄ± ANSI'dir** â€” sessizce yanlÄ±ÅŸ sonuÃ§ verir.
6. **AÃ§Ä±k dizi parametresi (`const X: TBytes`) Ã¶lÃ§Ã¼m artefaktÄ± Ã¼retir.**
   Bu ortamda `X[i]` ile okuma yerel deÄŸiÅŸkene gÃ¶re kayabiliyor.
   Motorun `VdbStrToBytes`/`VdbBytesToStr` kodunu "dÃ¼zeltme" yapÄ±p
   **gerÃ§ek bir off-by-one sokmak Ã¼zereydik** (bkz. bÃ¶lÃ¼m 7).
   Byte dizisi karÅŸÄ±laÅŸtÄ±rmasÄ± yaparken **iÅŸaretÃ§i** (`PByte`) kullan.
7. **`CryptUnprotectData` bu makinede Win32 87 veriyor.** `crypt32.dll`
   yalnÄ±z soneksiz `CryptProtectData`/`CryptUnprotectData` dÄ±ÅŸa aktarÄ±r
   (A/W varyantÄ± **yok** â€” `CryptAcquireContext` tuzaÄŸÄ±nÄ±n aynÄ±sÄ±).
   `CryptProtectData` Ã§alÄ±ÅŸÄ±yor, `CryptUnprotectData` Ã§alÄ±ÅŸmÄ±yor.
8. **DCPcrypt `Init(const Key: array of Byte; ...)` open-array
   parametresine dinamik dizi (`TBytes`) VERÄ°LMEZ.** Bu ortamda
   (FPC 3.2.2, i386) anahtar **sessizce yanlÄ±ÅŸ** okunuyor: aynÄ±
   anahtar/IV/dÃ¼z metin statik dizi ile verildiÄŸinde **48/48 bayt
   farklÄ±** ÅŸifreli metin Ã¼retiliyor. `ctr.lpr` ile baÄŸÄ±msÄ±z kanÄ±tlandÄ±.
   Her zaman Ã¶nce statik tampona `Move` edip statik diziyi geÃ§ir.
   Blok veri tamponlarÄ± iÃ§in de aynÄ± geÃ§erlilik geÃ§erli.
9. **Dinamik dizi 0 tabanlÄ±dÄ±r â€” 1 tabanlÄ± yazma hatasÄ± yapma.**
   `Result[ofs + 1]` Ã§Ä±ktÄ±yÄ± bir bayt kaydÄ±rÄ±r (ilk bayt Ã§Ã¶p, son bayt
   dÃ¼ÅŸer). `VDbPbkdf2Sha256` bu yÃ¼zden yanlÄ±ÅŸ Ã§Ä±kÄ±yordu. DoÄŸrusu
   `Result[ofs]`. (Bu, 8. maddedeki open-array sÄ±nÄ±fÄ±nÄ±n **ikinci**
   gerÃ§ek Ã¶rneÄŸi; ikisi de bulundu ve dÃ¼zeltildi.)
10. **`out` parametreli bir deÄŸiÅŸkeni aynÄ± fonksiyonda hem geÃ§ici
    tampon hem de Ã§Ä±ktÄ± hedefi olarak kullanma.** `out` parametrelerde
    FPC'nin temizleme davranÄ±ÅŸÄ± Ã¶lÃ§Ã¼mÃ¼ bozuyordu. Hata ayÄ±klama
    deÄŸiÅŸkeni `VDbCryptDbgKEnc := kEnc` gibi **paylaÅŸÄ±mlÄ±** atama
    yaparsa, fonksiyon sonundaki `FillChar(kEnc,0)` ile **kendisi de
    silinir** ve Ã¶lÃ§Ã¼m `00000000` gibi sahte sonuÃ§ verir. KarÅŸÄ±laÅŸtÄ±rma
    istiyorsan gerÃ§ek kopya al.
11. **Test yardÄ±mcÄ±larÄ± da hata ayÄ±klama kodudur.** Bu turda Ã¼Ã§ ayrÄ±
    sahte kÄ±rmÄ±zÄ± Ã¼retiler: `Hex()` `SetLength` hatasÄ±; bayt Ã§evirme
    yerine kaydÄ± **kÄ±saltan** (`Copy(cipher,0,i+1)`) test; ve baÅŸarÄ±da
    bile baÅŸarÄ±sÄ±zlÄ±k notunu yazdÄ±ran `Chk(..., Not)` Ã§aÄŸrÄ±sÄ±.
    KÄ±rmÄ±zÄ± testten Ã¶nce **Ã¶lÃ§Ã¼mÃ¼n doÄŸru olduÄŸunu** doÄŸrula.

---

## 7. YanlÄ±ÅŸ alarm kaydÄ± (okunmasÄ± Ã¶nemli)

Bu turda `VDbStrToBytes` iÃ§in "kritik bayt kaymasÄ± â†’ diskteki tÃ¼m metin
verileri bozuk" teÅŸhisi kondu ve **geÃ§ici olarak dÃ¼zeltildi**.
Ã–lÃ§Ã¼m yapÄ±ldÄ±ÄŸÄ±nda kaymanÄ±n **probun kendi aÃ§Ä±k dizi parametresinden**
kaynaklandÄ±ÄŸÄ±, motorun kodunun ise **doÄŸru** olduÄŸu anlaÅŸÄ±ldÄ±.
DÃ¼zeltme geri alÄ±ndÄ± ve doÄŸrulandÄ±: `sqltest` 859/859, her iki canlÄ±
`.odb` **SAGLAM**.

> UyarÄ±: `VDbCore.pas` iÃ§indeki `VdbStrToBytes`/`VdbBytesToStr`
> `Move(...)` desenini **deÄŸiÅŸtirmeyin**. Ã–lÃ§Ã¼m gerektiÄŸinde aÃ§Ä±k dizi
> parametresi kullanmayÄ±n.

### Bu turda dÃ¼zeltilen **sahte kÄ±rmÄ±zÄ±lar** (Ã¼rÃ¼n hatasÄ± DEÄÄ°LDÄ°)

| GÃ¶rÃ¼nen | GerÃ§ek |
|---|---|
| "PBKDF2 Ã§Ä±ktÄ±sÄ± `73` ile baÅŸlÄ±yor, RFC ile uyuÅŸmuyor" | **ÃœRÃœN HATASI.** `Result[ofs+1]` 1 tabanlÄ± yazma; dizi 0 tabanlÄ±. DÃ¼zeltildi â†’ vektÃ¶r birebir geÃ§ti. |
| "DoÄŸru parola doÄŸrulanmÄ±yor" | YukarÄ±daki hatanÄ±n sonucu. AynÄ± dÃ¼zeltmeyle yeÅŸile dÃ¶ndÃ¼. |
| "Ã‡Ã¶zme yanlÄ±ÅŸ plaintext dÃ¶nÃ¼yor" | **ÃœRÃœN HATASI.** `Init`'e dinamik dizi (open array) verilmesi; statik tampona Ã§evrilince Ã§Ã¶zÃ¼ldÃ¼. |
| "68 konumun 1'inde bayt Ã§evirme kaÃ§Ä±yor" | **TEST HATASI.** Test kaydÄ± kÄ±saltÄ±yordu, bayt Ã§evirmiyordu; son konum tam geÃ§erli kaydÄ± veriyordu. |
| "Anahtar bellekte silinmemiÅŸ" | **TEST HATASI.** Kontrol yalnÄ±z `unblob[1]`'e bakÄ±yordu ve baÅŸarÄ± notunu hata sanÄ±yordu. TÃ¼m 32 bayt iÅŸaretÃ§i ile doÄŸrulandÄ±. |

> Ders: **kÄ±rmÄ±zÄ± test â‰  Ã¼rÃ¼n hatasÄ±.** Bu turda 5 kÄ±rmÄ±zÄ±nÄ±n 3'Ã¼ gerÃ§ek
> Ã¼rÃ¼n hatasÄ±, 2'si test/Ã¶lÃ§Ã¼m hatasÄ±ydÄ±. Ã–nce Ã¶lÃ§Ã¼mÃ¼ doÄŸrula.

---

## 8. Derleme komutlarÄ± (kopyala-kullan)

```powershell
# Motor testi (kanonik)
& "D:\Onur_Yedek\mailler\lazarus\lazbuild.exe" -B "<veritabani>\sqltest.lpi"

# DLL (kanonik yol; .lpi yanlislikla .exe uretiyor)
powershell -ExecutionPolicy Bypass -File "<veritabani>\build_dll.ps1"

# Arayuz
& "D:\Onur_Yedek\mailler\lazarus\lazbuild.exe" -B "<veritabani>\yonetim\had.lpi"

# Kripto birimi (DCPcrypt yollari lazim)
& "D:\Onur_Yedek\mailler\lazarus\fpc\3.2.2\bin\i386-win32\ppc386.exe" -O2 `
  -Fu"<veritabani>" -Fu"<veritabani>\dcpcrypt" `
  -Fu"<veritabani>\dcpcrypt\Ciphers" -Fu"<veritabani>\dcpcrypt\Hashes" `
  -FU"<cikti>" -FE"<cikti>" "<veritabani>\vdbcrypttest.lpr"
```

> `sqltest.lpr` `FileUtil` kullandigi icin LCL/lazutils yollari da
> gerekiyor; `lazbuild` ekledigi icin sorun yok. Dogrudan `ppc386`
> ile derlerken bunlari da ekle:
>
> ```powershell
> -Fu"<lazarus>\components\lazutils\lib\i386-win32" `
> -Fu"<lazarus>\lcl\units\i386-win32" `
> -Fu"<lazarus>\packager\units\i386-win32"
> ```

---

## 9. GÃ¼ncel durum (2026-10-05)

### YeÅŸil olanlar

| Paket | SonuÃ§ |
|---|---|
| `sqltest` | **905/905** (82 grup) â€” 859 eski + 46 yeni ÅŸifreleme |
| `vdbcrypttest` | **60/60** |
| `vdbapitest` | **123/123** (35 export) |
| `vdbclienttest` | **71/71** |

Kriptografik Ã§ekirdek **dÃ¶rt baÄŸÄ±msÄ±z kanÄ±tla** doÄŸrulandÄ±:
RFC 4231 Ã—2 (HMAC-SHA256), RFC 7914 (PBKDF2), FIPS-197 C.3 (AES-256
blok), 68 konumlu bayt bozma (tamamÄ± yakalandÄ±). GidiÅŸ-dÃ¶nÃ¼ÅŸ hem
testte hem baÄŸÄ±msÄ±z iÅŸaretÃ§i tabanlÄ± Ã¶lÃ§Ã¼mde **0 farklÄ± bayt**.

`build_dll.ps1` de gÃ¼ncellendi: `VDbCore â†’ VDbCrypt â†’ DCPcrypt` zinciri
koptuÄŸu iÃ§in DCPcrypt yollarÄ± eklendi (aksi halde "Can't find unit
dcpcrypt2 used by VDbCrypt").

### Bu turda dÃ¼zeltilen iki gerÃ§ek Ã¼rÃ¼n hatasÄ±

1. `VDbPbkdf2Sha256`: dinamik diziye 1 tabanlÄ± yazÄ±m â†’ Ã§Ä±ktÄ± bir bayt
   kayÄ±yordu. (`Result[ofs + 1]` â†’ `Result[ofs]`)
2. `VDbCryptEncrypt`/`VDbCryptDecrypt`: `Init`'e anahtar dinamik dizi
   (open array) olarak veriliyordu â†’ anahtar yanlÄ±ÅŸ okunuyordu.
   Statik tampona `Move` edilip Ã¶yle geÃ§iliyor.

AyrÄ±ca Encrypt-then-MAC sÄ±rasÄ± dÃ¼zeltildi: `plainLen` artÄ±k etiket
doÄŸrulanmadan Ã¶nce okunmuyor.

### SÄ±rada

**AdÄ±m 11 â€” Mutasyon kanÄ±tÄ± (â‰¥4 bozma)**: **TAMAMLANDI**. SonuÃ§: 4/5 bozma
kÄ±rmÄ±zÄ±ya dÃ¶ndÃ¼; 4. bozma (FillChar kaldÄ±rÄ±lmasÄ±) maskelendi â€” Get'te ardÄ±ndan
`SetLength(Value,0)` olduÄŸu iÃ§in test onu yakalayamaz. IV'siz HMAC mutasyonu
(5) vdbcrypttest'in 68-konum dÃ¶ngÃ¼sÃ¼ ile doÄŸrulandÄ± (16 konum kaÃ§arken 0 kaÃ§madÄ±).
Adaylar:
1. `AppendRec`'te `VDB_FLAG_ENCRYPTED` bayragini **dusurmek**
   â†’ karÄ±ÅŸÄ±k dosya testi kÄ±rmÄ±zÄ±ya dÃ¶nmeli (sifreli veri dÃ¼z metin sanÄ±lÄ±r).
2. `Get`'te etiket doÄŸrulamasÄ±nÄ± **atlamak** (decrypt'den Ã¶nce kontrol
   kaldÄ±rÄ±lÄ±rsa) â†’ sessizce bozuk veri dÃ¶ner, test kÄ±rmÄ±zÄ±ya dÃ¶nmeli.
3. `Compact`'ta bayraÄŸÄ± yine `VDB_FLAG_PUT` yapmak
   â†’ Compact sonrasÄ± okuma hata vermeli.
4. `DecryptValue`'de `FillChar(Value,0)` temizliÄŸini kaldÄ±rmak
   â†’ "veri DÃ–NDÃœRÃœLMEDÄ°" kontrolÃ¼ kÄ±rmÄ±zÄ±ya dÃ¶nmeli.
5. `VDbCryptHmacSha256` etiket kapsamÄ±ndan `IV`'yi Ã§Ä±karmak
   â†’ 68 konumlu bayt bozma testinde IV konumlarÄ± kaÃ§malÄ±.

**AdÄ±m 17/18 — DLL, VDBClient, had, belgeler** — 17 **Bitti (2026-10-05)**:
`vdbapi_core.pas`/`vdbapi.lpr`'e 10 yeni export eklendi
(`VdbEncryptEnable/Disable/IsEncrypted/CreateKeyFile/OpenKeyFile/KeyPath/Fingerprint/
HasEncryptedRecords/RekeyWithPassword`), `vdbapi.dll` derlendi, `vdbapitest` 123/123.
`VDBClient.pas` ve `had` UI export'larÄ± henüz yok; 18. adımda belgelar güncellendi.
