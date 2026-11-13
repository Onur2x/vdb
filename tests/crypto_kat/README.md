# tests/crypto_kat — VDbCrypto KAT koşucusu

VDbCrypt / VDbKdf / VDbPageCrypto primitiflerini resmî RFC/NIST bilinen-yanıt
vektörleriyle mühürleyen bağımsız Free Pascal test koşucusu. **Üretim koduna
dokunmaz**; sadece API'yi çağırır ve PASS/FAIL raporlar.

Vektör kaynakları ve dürüstlük notları: [`Vectors.md`](Vectors.md).

## Derleme (FPC 3.2.4)

```bat
fpc -FuD:\veritabani -FUD:\veritabani\tests\crypto_kat\lib D:\veritabani\tests\crypto_kat\kat_runner.lpr
```

> Not: `-Fu`/`-FU` bayrakları FPC'de yola **bitişik** yazılmalıdır; `-Fu D:\...`
> (boşluklu) biçiminde yollar kaynak dosya sanılıp unit arama yolu boş kalır.

- `-Fu D:\veritabani` : VDbCrypt ve saf Pascal çekirdek birimlerine bağımlı.
- `-FU ...lib\` : üretilen .ppu/.o dosyaları `lib\` içinde kalır.
- Linux'ta Argon2id iş parçacıkları için `ccthreads` zaten `{$ifdef UNIX}` ile
  bağlanır.

## Çalıştırma

```bat
tests\crypto_kat\kat_runner.exe
```

- Her satır: `PASS|FAIL|SKIP | primitif | vektör | kaynak`.
- Özet satırı: `N passed / M failed / K skipped`.
- **Çıkış kodu:** 0 = hepsi yeşil, 1 = en az bir FAIL (CI için).

## Ne mühürleniyor

| Birim | Kapsam |
|---|---|
| `kat_sha256.pas` | FIPS 180-4 vektörleri + 56B sınır + 1M mesaj |
| `kat_hmac_sha256.pas` | RFC 4231 Case 1–7 (>64B anahtar limitasyonu dahil) |
| `kat_aes256gcm.pas` | 6 GCM vektörü (seal+open+tahrifat reddi), uzunluk guard'ları, `VDBAEAD1` zarf düzeni, legacy CTR+HMAC zarf |
| `kat_blake2b.pas` | RFC 7693 `"abc"` + hashlib-çapraz vektörler, OutLen 1..64 sözleşmesi |
| `kat_argon2id.pas` | RFC 9106 §5.3 vektörü, determinizm, parametre hassasiyeti, Blake2bLong yolu, girdi guard'ları |
| `kat_page_envelope.pas` | 4124B sayfa zarfı düzeni + AAD pin'leme + tahrifat/guard yolları + key-check/parmak izi |

## Sınırlamalar / TODO

- GCM ct/tag değerleri bağımsız OpenSSL koşumu ile üretildi; **NIST CAVP
  `gcmEncryptExtIV256.json` ile çapraz kontrol bu ortamdan yapılamadı
  (404)** → internete erişimli makinede tamamlanacak (detay Vectors.md).
- Argon2id brief'te "RFC 9128" deniyordu; doğru kaynak RFC 9106 §5.3'tür
  (Vectors.md'de düzeltme notu).
- GCM nonce-tekrarı tespiti primitifte yok — BASELINE.md §5 borcu olarak
  SKIP notu ile seal'lendi.
- HMAC >64B anahtar limiti üretim kodunda değişirse Case 6/7 testi
  güncellenmeli.
