# tests/crypto_fixtures — Kriptografik uyumluluk fixture paketi (Goc Plani Adim 2A)

Bu paket, **dcpcrypt-kaldirma goci (Adim 2B) oncesindeki** kodun urettiği eski
formatli dosyalari (eski-format dosyaları) bit duzeyinde sabitler. Amac: VDbCrypt.pas
icindeki saf Pascal primitifleri OpenSSL provider'ina tasirken **sessiz
kirim-kirilmazi (kırılmazlık) kirilimini** yakalamak.

## KURAL — GOC KIRILMAZLIK KAPISI (kirma kurali)

> **2B göçünden sonra `gen_fixtures verify` exit-code 0 donmüyorsa GÖÇ KIRICIDIR:
> migration durdurulur, fixture'i çözemeyen değişiklik geri alınır / düzeltilir.**
> Fixture dosyaları "test verisi" degil, **eski-format veri sozlesmesidir**:
> musteri elindeki `.key`/`.odb`/zarf dosyalari bu bicimdedir. KOD DEGISEBILIR,
> BICIM DEGISEMEZ.

Kapsam (verify'nin yokladigi yuzeyler): `.key` v1 (PBKDF2) okuma, `.key` v2
(Argon2id) okuma + yazma, sayfa zarfi (`VDbPageOpen`), kayit zarfi
(`VDBAEAD1` AEAD + legacy CTR+HMAC okuma), SCRAM-SHA-256 verifier turetimi,
sifreli depo acma (`TVdbPageEngine` parola → PBKDF2-200000 + keycheck).

## Dizin yapisi

```
crypto_fixtures\
  gen_fixtures.lpr / .lpi   uretic + dogrulayici (tek dosya)
  build.ps1                 derleme kalibi (powershell -File ile kosulur)
  manifest.md               fixture tablosu + byte offset tablolari + sha256
  README.md                 bu dosya
  fixtures\                 uretilmis fixture'lar (asagidaki "git -f" notuna bakin)
    key_v1_pbkdf2.key            v1 .key (PBKDF2, iter=1000)  [deterministik, pinli]
    key_v2_argon2id.key          v2 .key sabit tuz            [deterministik, pinli]
    key_v2_argon2id_write.key    canli VDbKeyFileWrite        [RNG salt — verify kapisi]
    page_envelope_v1.bin         4124 B sayfa zarfi           [deterministik, pinli]
    record_envelope_v1.bin       VDBAEAD1 kayit zarfi         [deterministik, pinli]
    record_legacy_v1.bin         eski CTR+HMAC zarfi          [RNG IV — verify kapisi]
    scram_verifier.txt           SCRAM-SHA-256 ornek          [deterministik, pinli]
    sha256.txt                   her kosumda yenilenen hash anlik goruntusu
    store_odb_v1\                canli sifreli depo           [RNG — verify kapisi]
      fixture.odb  .wal  .gen  .idx
  lib\                      FPC birim ciktilari (git'de yok)
```

## Derleme

FPC 3.2.4 i386-win32. `-Fu` bayraklari yola **bitisik** yazilmalidir (bosluklu
bicim sessizce bozar). PowerShell inline `-Command` bu ortamda bozuk; daima:

```bat
cd /d D:\veritabani\tests\crypto_fixtures
powershell -ExecutionPolicy Bypass -File build.ps1
```

(cmd ile elle:)

```bat
fpc -MObjFPC -Scghi -O1 -g -l -vewnhibq -FuD:\veritabani "-FUD:\veritabani\tests\crypto_fixtures\lib" gen_fixtures.lpr
```

Exe cwd'ye (`gen_fixtures.exe`) duser; `*.exe` zaten .gitignore'da.

## Koshum

```bat
gen_fixtures gen        :: fixture'lari fixtures\ altina yeniden uretir + self-check
gen_fixtures verify     :: MEVCUT fixture dosyalarini cozer; PASS/FAIL basar
```

- Cikis kodu = basarisiz kontrol sayisi (0 = yesil).
- `verify` fixture dosyalarini salt-okunur acar; `gen` hepsini sifirdan
  yeniden yazrar (Argon2 t=3/m=64MiB/p=4 ve PBKDF2-200000 yuzunden ~1-2 dk
  surebilir — **normaldir**).
- `verify` 2B sonrasinda kosulacak ana kapidir; CI'a `gen_fixtures verify` +
  exit-code kontrolu olarak baglanabilir.

## Git notu (ONEMLI)

Kok `.gitignore` `*.key`, `*.odb`, `*.wal`, `*.idx` ve `*.exe` kalibini
globally yok sayar ve paket fixture uzantilarini geri-ekleyen bir `!` kurali
YOKTUR (bu paket hicbir mevcut dosyayi duzenlemez). Bu yuzden fixture'lar
ilk kez su sekilde eklenmelidir:

```bat
git add -f tests/crypto_fixtures/fixtures
```

(Aks halde `fixtures\*.key`, `store_odb_v1\*` sessizce atlanir ve kapissiz
bir commit olur.)

## Pin guncelleme disiplini

Deterministik fixture'larin sha256 degerleri `gen_fixtures.lpr` icindeki
`PIN_*` sabitlerinde durur. Yalniz **bilincli, onaylanmis bir format
degisikliginde** (orn. 2C'de yeni format yazimina gecis) guncellenir:
`gen_fixtures gen` -> bastigi `PINS` blogunu sabitlere yapistir -> tekrar
derle -> `gen_fixtures verify` yesil olmali. Beklenmedik pin degisimi =
primitifte davranis kirilmasi = GOC KIRICI.

## Baglantilar

- Format sozlesmeleri + offset tablolari: `manifest.md`
- Goc plani: `GOC_V2_V3.md` / dcpcrypt-kaldirma plani Adim 2A/2B
- Karsilastirmali KAT (RFC/NIST vektorleri): `tests\crypto_kat\`
