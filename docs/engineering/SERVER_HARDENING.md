# Sunucu sertlestirme (R-4) - uygulanan korumalar

Bu belge `vdbserver` / `TVdbPgServer` tarafinda **gercekten uygulanan**
koruma kurallarini ve bunlarin sinirlarini kaydeder. Amac, sertlestirme
iddialarini kanitlanabilir davranisa baglamak: her madde icin ya kod
yolu ya da kalici kapi vardir.

## 1. Dinleme adresi ve `--trust`

| Durum | Sonuc |
|---|---|
| En az bir `--user K:P` var, `--host` yok | `0.0.0.0` (tum arayuzler), SCRAM zorunlu |
| `--user` var, `--host ADRES` | Verilen adrese baglanir; cozulemezse baslatma reddedilir |
| `--trust`, `--host` yok | **Yalniz `127.0.0.1`** + kalin uyari |
| `--trust --host 0.0.0.0` (veya baska yerel olmayan adres) | **Reddedilir** (exit 2) |
| Ne `--user` ne `--trust` | Reddedilir (exit 2) |

- Adres cozumleme `VdbResolveListenHost` (VDbNet) icinde yapilir ve
  **fail-closed**'dir: yalniz noktali IPv4 kabul edilir, `StrToNetAddr`
  sonucu 0 olursa `0.0.0.0`'a sessiz dusme yerine dinleme basarisiz olur.
- `READY` satiri baglanilan adresi acikca yazar:
  `READY port=<n> bind=<adres> auth=<scram|trust> tls=<on|off>`.
- `/metrics` ucu da ayni adrese baglanir (trust modunda loopback).

## 2. TLS

### Sunucu tarafi
- `--tls CERT KEY` olmadan `--require-tls` baslatmayi reddeder.
- `--require-tls` iken TLS'siz baglanti kimlik dogrulamadan once
  `28000` ile reddedilir.
- Baglam olusturulurken `SSL_OP_NO_SSLv2 | SSL_OP_NO_SSLv3` uygulanir;
  indirgeme (downgrade) yolu yoktur.

### Istemci tarafi (`TVdbTlsContext.CreateClient`)
- **CA dosyasi zorunludur**; bos verilirse istisna atilir. Dogrulamayi
  kapatan bir parametre/mod yoktur (`SSL_VERIFY_NONE` kullanilmaz).
- Zincir dogrulamasi `SSL_VERIFY_PEER` + `SSL_CTX_load_verify_locations`
  ile yapilir; el sikismasi sonrasi `SSL_get_verify_result` tekrar
  kontrol edilir.
- Sunucu adi verilirse `SSL_get_peer_certificate` + `X509_check_host`
  ile eslesme aranir; uyusmazsa baglanti kurulmaz.
- Gerekli OpenSSL sembolleri yoksa istemci **kurulmaz** (sessiz
  dogrulamasiz baglanti yok).

## 3. Kimlik dogrulama denemesi sinirlama

Varsayilanlar `TVdbPgServer` icinde:

| Ayar | Varsayilan | Anlam |
|---|---|---|
| `AuthMaxFailures` | 5 | Kullanici basina pencere icindeki azami hata |
| `AuthFailureWindowSeconds` | 60 | Sayac penceresi |
| `AuthLockoutSeconds` | 30 | Esik asilinca kilit suresi |
| `AuthGlobalMaxFailures` | 200 | Pencere icinde tum kullanicilar toplami |

- Basarisiz SCRAM denemesi (`28P01`) sayaci artirir; esik asilinca o
  kullanici `AuthLockoutSeconds` boyunca reddedilir. Kilitliyken SCRAM
  yuku alinmaz, istemciye `cok fazla basarisiz kimlik dogrulama denemesi;
  gecici olarak kilitli` (`28P01`) doner.
- Basarili giris o kullanicinin sayacini ve kilidini siler.
- Toplam esik asilirsa (parola taramasi) kullanici adindan bagimsiz
  olarak herkes gecici kilitlenir.
- `0` ilgili siniri devre disi birakir.
- Bilinmeyen kullanici ile yanlis parola **ayni** genel mesaji alir
  (hesap numaralandirmasi icin ek bilgi sizmaz).
- **Sinirlar:** cezalar yalniz bellekte tutulur (yeniden baslatma
  sifirlar), IP/ag bazli bir sinir yoktur, kalici (diskte) kilit yoktur.
  Coklu surec/cekirdek dagitimi kapsam disidir.

## 4. Kalici kapilar

| Kapi | Konum | Kapsam |
|---|---|---|
| `server_harden.exe` | `tests/server_harden/server_harden.lpr` | loopback tablosu, adres cozumleme, gercek bind/red |
| `auth_throttle.exe` | `tests/server_harden/auth_throttle.lpr` | ceza defteri: esik, kilit, pencere, global tarama, sifirlama |
| `tls_client_gate.exe` | `tests/tls_client/tls_client_gate.lpr` | CA zorunlulugu, yanlis CA/yanlis ad reddi, dogru CA kabulu |

TLS kapisi OpenSSL'e ihtiyac duyar; `VDB_SSL_DLL`, `VDB_CRYPTO_DLL` ve
`VDB_TLS_FIXTURES` ortam degiskenleriyle yonlendirilir. Kutuphaneler
yoksa kapi `77` ile atlandigini bildirir (sessiz gecmez).

## 5. Kapsam disi (bilerek yapilmayanlar)

- TLS 1.2 alt sinirinin zorlanmasi: OpenSSL 1.0.2'de
  `SSL_CTX_set_min_proto_version` yok; SSLv2/SSLv3 kapatmakla yetinildi.
- Sertifika iptal listesi (CRL/OCSP) dogrulamasi.
- Kalici kilit, IP bazli hiz siniri, hesap kilidini yonetici arayuzunden
  acma.
- Baglanti basina CPU/memory kotasi.
