# Guvenlik politikasi (SECURITY)

VDB, Free Pascal ile yazilmis gomulu bir iliskisel veritabani motorudur.
Bu belge **guvenlik acigi bildirimi** icin tek giris noktasidir.

## Desteklenen surumler

| Surum | Durum |
|---|---|
| `main` (v3 sayfa motoru) | Duzeltme alir |
| v2 backend (`VDbBackendV2`, `VDbCore`) | **Yalniz salt okunur** uyumluluk; guvenlik duzeltmesi sozu verilmez |
| v3 oncesi dallar | Desteklenmez |

## Guvenlik acigi nasil bildirilir

**GitHub Security Advisories** uzerinden bildirin:

<https://github.com/Onur2x/vdb/security/advisories/new>

Bu yol ozel (private) bir kanal acar; konu kamuya acilmadan once birlikte
degerlendirilir. Acik bir sorun icin dogrudan `main`'e yama gondermeyin.

Bildirimde sunlari eklemek inceleme suresini kisaltir:

- etkilenen surum/commit ve platform (FPC surumu, isletim sistemi),
- en kucuk tekrar uretme adimi (SQL, Pascal cagrisi veya ag istegi),
- beklenen ve gerceklesen davranis,
- varsa `VERIFY` / `SHOW STATS` ciktisi ya da bozuk dosyanin nasil olustugu,
- sifreleme ile ilgiliyse: kullanilan KDF/provider (`builtin` / `openssl`).

**Gercek kimlik bilgisi, anahtar veya musteri verisi gondermeyin.**
Tekrar uretme icin sentetik veri yeterlidir.

## Kapsam

Bildirim kapsaminda olanlar:

- VDB motoru (`VDb*.pas`), SQL yolu, sayfa/WAL/kurtarma yollari,
- VDBS TCP sunucusu (`VDbSqlServer.pas`, `VDbNet.pas`),
- PostgreSQL wire sunucusu (`VDbPgWire.pas`) ve TLS entegrasyonu
  (`VDbTls.pas`),
- kripto cekirdegi (`VDbCryptoCore.pas`, `VDbKdf.pas`) ve KAT/self-test
  yollari,
- yedek/PITR (`BACKUP TO`, `RECOVER TO TIMESTAMP`, `VerifyBackup`).

Kapsam disi (ayrintili liste `docs/security/THREAT_MODEL.md` bolum 6):

- isletim sistemi seviyesinde yetkili saldirgan,
- ag seviyesinde DDoS,
- v2 backend'de yeni bulunan hatalar (salt okunur uyumluluk),
- harici OpenSSL kurulumunun kendi zafiyetleri (kutuphane tarafinda
  bildirilmelidir).

## Bilinen ve kabul edilmis riskler

Bunlar **acik** olarak kabul edilmistir; bildirim olarak tekrar
degerlendirilmez (ayrinti ve kod kaniti: `docs/security/THREAT_MODEL.md`,
risk register):

- Sifreleme **varsayilan kapalidir**; sifresiz bir `.odb` dosyasini ele
  geciren kisi veriyi okur (R-10).
- builtin kripto yollari (AES-256-GCM, Argon2id, SHA-256) saf Pascal'dir;
  cache-timing yan kanallarina karsi OpenSSL kadar sert degildir ve
  bagimsiz bir kripto incelemesinden gecmemistir. **FIPS iddiasi yoktur**
  (R-07; `docs/architecture/CRYPTO_ADR.md` EK-B).
- Pascal heap'te anahtar sifirlama garantisi yoktur (R-07).
- in-process cagiran kod RBAC/RLS'i atlayabilir; yetkilendirme yalniz SQL
  yolu uzerinden uygulanir (R-12).
- VDBS protokolunde TLS ve giris hiz siniri yoktur; bu protokol **guvenilmeyen
  aglarda kullanilmamalidir** (R-02, R-03). Guvenilmeyen ag icin PG wire +
  TLS (`RequireTls`) kullanin.

## Guvenlik durusu hakkinda durust sinirlar

Bu proje "production-ready" veya "denetlenmis" olarak etiketlenmez.
Neyin korundugu ve neyin korunmadigi risk register'da tek tek yazilidir;
yeni bir saldiri yuzeyi eklendiginde ayni commit'te guncellenir.

## Duzeltme akisi

1. Bildirim ozel kanaldan alinir ve tekrar uretilir.
2. Etki ve onem `THREAT_MODEL.md` risk register'a islenir.
3. Duzeltme + **kapı** (test) ayni commit'te gelir; risk `kapali` olur ve
   kapatan kapi adi yazilir.
4. Duzeltme surum notlarina (CHANGELOG) ve gerekirse bir Security Advisory
   olarak kamuya acilir.
