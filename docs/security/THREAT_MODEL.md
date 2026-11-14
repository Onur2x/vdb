# VDB tehdit modeli

Bu belge, VDB'nin **bugunku** saldiri yuzeyini ve kabul edilmis risklerini
kayit altina alir. Amac guvenli oldugunu iddia etmek degil; neyin
korundugunu, neyin korunmadigini ve her riskin arkasindaki kod kanitini
tek yerde gostermek.

- Kapsam: gomulu (in-process) kullanim, VDBS TCP protokolu, PostgreSQL wire
  protokolu, TLS, sifreleme, yedek/PITR, dosya sistemi.
- Yontem: STRIDE + risk register.
- Dil kurali: bu belge de `docs/engineering/` gibi ASCII Turkce yazilir
  (repo arama/`grep` kolayligi icin).

> Durum: **on hazirlik (pre-release)**. Sozdizimi ve satir numaralari bu
> commit'in koduna aittir; kod degisirse risk kanitlari da guncellenmelidir.

## 1. Varliklar

| # | Varlik | Nerede durur |
|---|---|---|
| A1 | Kullanici verisi (sayfalar, satirlar, sema) | `<db>.odb` |
| A2 | Commit gunlugu (cokme kurtarma) | `<db>.odb.wal` |
| A3 | Degisim gunlugu / PITR taban imaji | `<db>.odb.log/`, `<db>.odb.gen` |
| A4 | Acilis indeks onbellegi | `<db>.odb.idx` |
| A5 | Sifreleme anahtarlari (DEK/KEK, parola turevleri) | yalniz bellekte + sifreli key metadata |
| A6 | Kimlik bilgileri | sunucu yapilandirmasi (parola), PG icin SCRAM dogrulayici |
| A7 | Sorgu/oturum icerigi (prepared SQL, sonuc kumesi) | bellek + tel uzerinde |
| A8 | Yedekler | `BACKUP TO` hedefi |

## 2. Guven sinirlari (trust boundaries)

```
 [uygulama kodu]  --A1..A8 dosya erisimi-->  [isletim sistemi / disk]
        |
        | in-process cagri (ayni adres alani, ayricalik yok)
        v
 [VDB motoru]  <--VDBS TCP-->  [uzak istemci]      (kimlik: kullanici/parola)
        |      <--PG wire-->   [psql / surucu]      (kimlik: SCRAM-SHA-256)
        |
        +--> [TLS katmani]  --yalniz OpenSSL varsa-->
```

Sinir noktalari ve bugunku durumu:

| Sinir | Durum |
|---|---|
| B1 uygulama <-> motor (in-process) | **Sinir yok.** Motoru cagiran kod tam yetkilidir; RBAC/RLS yalniz SQL yolu uzerinden uygulanir. |
| B2 ag <-> VDBS sunucusu | Kimlik dogrulama var (duz metin parola), **TLS yok**, hiz siniri yok. |
| B3 ag <-> PG wire sunucusu | SCRAM-SHA-256, opsiyonel TLS, hiz siniri var; `RequireTls` ile TLS zorunlu kilinabilir. |
| B4 motor <-> disk | Sayfa basina CRC32 + WAL. **Sifreleme opsiyonel**; acikken sayfa duzeyinde AES-256-GCM. |
| B5 admin <-> yedek/PITR | `BACKUP TO` / `RECOVER TO TIMESTAMP`; yedek dosyasi ayricalikli islem sayilir. |
| B6 tedarik zinciri | Saf Pascal; **varsayilan olarak hicbir harici DLL yuklenmez**. Opsiyonel OpenSSL/TLS DLL yolu vardir. |

## 3. Aktorler ve yetenekleri

| Aktor | Erisimi | Varsayilan yetenek |
|---|---|---|
| Yerel uygulama | in-process | Tam veritabani yetkisi (B1 sinirinda ayricalik yok). |
| Yerel kullanici (ayni makine, baska surec) | dosya sistemi | A1-A4 dosyalarini kopyalayabilir/silebilir; sifreleme kapaliysa veriyi okur. |
| Ag istemcisi (VDBS) | TCP | El sikisma sonrasi `LOGIN` disinda komut yok; ama baglanti basina 1 GB'a kadar tampon ayirtabilir (R-01). |
| Ag istemcisi (PG wire) | TCP | SCRAM oncesi yalniz `StartupMessage` (64 KB sinir); sonra protokol mesajlari (64 MB sinir). |
| Kimligi dogrulanmis uzak kullanici | SQL | RBAC/RLS'e tabi; kaynak tuketim kotasi **yok** (R-06). |
| Yedek dosyasina erisen kisi | dosya | Sifresiz veritabaninda tam veri; sifreli veritabaninda parola olmadan sayfalar okunamaz. |
| Aritmetik/kripto yan kanal gozlemcisi | ayni makine | builtin AES-GCM/Argon2 icin cache-timing sinyali toplayabilir (R-07, kabul edilmis). |
| Kotu niyetli tedarikci | build | Kaynak agacina mudahale; imzalama/provenance yok (R-08). |

Yeteneği **olmayan** aktorler (bugun itibariyle): SQL'den dosya okuma/yazma
(`COPY`, `LOAD DATA`, `OUTFILE`, `ATTACH` parser'da yok), SQL'den harici
komut calistirma, plugin/eklenti yukleme (plugin mekanizmasi yok).

## 4. STRIDE

Her satir bir saldiri sinifidir; "Kanit" kolonu koddaki mevcut davranisi,
"Durum" kolonu risk register'a baglanir.

| STRIDE | Senaryo | Bugunku davranis / kanit | Durum |
|---|---|---|---|
| **S**poofing | VDBS'e yanlis parolayla giris | `VDbSqlServer.pas` `LOGIN`: `if (user = FServer.FUser) and (pass = FServer.FPass)` — duz metin, sabit zamanli degil | R-02, R-03 |
| Spoofing | PG'de kullanici adi enumerasyonu | Bilinmeyen kullanici ve yanlis parola **ayni** hata mesajini verir; `DoScramAuth` | kontrollu |
| Spoofing | TLS'te sahte sunucu | Istemci CA dosyasi zorunlu, `SSL_VERIFY_PEER`, `X509_check_host` (`VDbTls.pas`) | kontrollu |
| **T**ampering | Bozuk sayfa / bit cakismasi | Sayfa basina CRC32; `VERIFY` ve `page_integrity` kapisi | kontrollu |
| Tampering | Yedegi sessizce bozma | `VerifyBackup` tek bayt degisimini reddeder (`backup_restore` B0-B24) | kontrollu |
| Tampering | WAL'e mudahale | WAL kayitlarinda magic/CRC; bozuk kayit replay'i keser (`wal_crash` kapisi) | kontrollu |
| **R**epudiation | Kim ne zaman ne yazdi | Degisim gunlugu (`.log/` + `.gen`) PITR icin tutulur; **kullanici kimligi loglanmaz** | R-09 |
| **I**nformation disclosure | Sifresiz `.odb` dosyasinin kopyalanmasi | Sifreleme opsiyonel ve varsayilan **kapali**; dosyayi alan veriyi okur | R-10 |
| Information disclosure | Anahtarlarin bellekte kalmasi | Pascal heap zeroization garantisi yok (CRYPTO_ADR K4) | R-07 |
| Information disclosure | VDBS trafiginin dinlenmesi | TLS yok; parola ve SQL duz metin gider | R-02 |
| Information disclosure | Sorgu sonucunun yetkisiz role sizmasi | RLS politikasi + `RequirePriv` SELECT/INSERT/UPDATE/DELETE yollarinda (`VDbExecutor.pas`) | kontrollu |
| **D**enial of service | Tek baglantiyla dev bellek ayirma | VDBS `VdbRecvStr`: `n > $40000000` reddedilir → **1 GB'a kadar kabul** (`VDbNet.pas:416-427`) | R-01 |
| DoS | Baglanti havuzunu doldurma | `FMaxConns` varsayilan 64; asildiginda `'kapasite dolu'`. Idle timeout **yok** | R-04 |
| DoS | Pahali sorgu | Sorgu maliyet/zaman limiti yok | R-06 |
| DoS | Kilitlenme/oturum kapatmama | PG wire'da baglanti basina thread; kapanma `GcFinished`/`Stop` | R-04 |
| **E**levation of privilege | SQL'den dosya/komut | Boyle bir yuzey yok (parser'da `COPY`/`OUTFILE`/`ATTACH` yok) | kontrollu |
| Elevation of privilege | RBAC atlatma | `RoleCan`/`RequirePriv`; `GRANT`/`REVOKE`/`CREATE POLICY` parser'da, `ExecPolicy` executor'da | kontrollu (kapi yok, R-11) |
| Elevation of privilege | `--trust` modunda uzak erisim | `VdbResolveListenHost` trust + loopback disi adresi **reddeder** (`server_harden` S11) | kontrollu |
| Elevation of privilege | Simetrik olmayan yetki: in-process | Motoru cagiran kod RBAC'i atlayabilir (B1). Tasarim geregi; belgelenmis sinir | R-12 |

## 5. Risk register

Onem: **Y** = yuksek, **O** = orta, **D** = dusuk. "Durum" alaninda
`acik` = cozulmedi, `kabul` = bilincli olarak kabul edildi, `kapali` =
cozuldu ve kapiyla korunuyor.

| ID | Risk | Onem | Kanit | Durum | Sonraki adim |
|---|---|---|---|---|---|
| R-01 | VDBS'te kimlik dogrulama **oncesi** gelen uzunluk alani ile 1 GB'a kadar bellek ayirma | Y | `VDbNet.pas:416-427` (`n > $40000000`), `VDbSqlServer.pas:219-229` (QUERY oturum kontrolunden once okunur) | acik | Protokol frame siniri (orn. 1 MB) + oturum yoksa govdeyi okumadan reddet |
| R-02 | VDBS'te TLS yok; parola ve SQL duz metin; karsilastirma sabit zamanli degil | Y | `VDbSqlServer.pas:251-271` | acik | VDBS'e TLS ekle veya yalniz loopback'e bagla; sabit zamanli karsilastirma |
| R-03 | VDBS'te giris hiz siniri/kilit yok (kaba kuvvet) | Y | `VDbSqlServer.pas` LOGIN; `auth_throttle` yalniz PG yolunu kapsar | acik | PG'deki `AuthMaxFailures` altyapisini VDBS'e bagla |
| R-04 | Idle/query timeout yok; baglanti slotlari tuketilebilir | O | `VDbSqlServer.pas:380-384`, PG ana dongusu `VDbPgWire.pas:2026-2032` | acik | Baglanti basina idle timeout + kapanma |
| R-05 | TLS alt siniri pinlenmemis (TLS 1.0/1.1'e izin veren kutuphane) | O | `VDbTls.pas` yalniz `SSL_OP_NO_SSLv2\|SSLv3` | acik | `TLS1_2_VERSION` min pinle |
| R-06 | Kimligi dogrulanmis kullanici icin kota/maliyet limiti yok (CPU, bellek, satir sayisi) | O | Calisma zamani limiti arayan kod yok | acik | Sorgu suresi + sonuc satiri tavani |
| R-07 | builtin kripto yan kanallara karsi OpenSSL kadar sert degil; bagimsiz inceleme yok; heap zeroization garantisi yok | O | `docs/architecture/CRYPTO_ADR.md` EK-B, K4 | kabul | Bagimsiz kripto incelemesi; mumkunse `SecureZeroMemory`/volatile temizleme |
| R-08 | Tedarik zinciri: imzalama/provenance yok; opsiyonel OpenSSL DLL yuzeyi | O | Depoda imza/SBOM dosyasi yok | acik | `p7-sbom` ile SBOM + imzalama karari |
| R-09 | Denetim izinde kullanici kimligi yok (degisim gunlugu yalniz veri degisimini tutar) | D | `VDbChangeLog.pas` kayit basligi: Kind/Seq/TsMs/TableId/Key | acik | Denetim gunlugune oturum/kullanici alani ekle |
| R-10 | Sifreleme varsayilan kapali; dosya kopyasi tam veri | O | Sifreleme yalniz parola verilince etkin | kabul | Belgelerde acikca yaz (README'de yazildi) |
| R-11 | RBAC/RLS kodu var ama **kapi yok**; regresyon sessiz kalabilir | O | `VDbTable.pas` `RequirePriv`/`RoleCan`; `tests/` icinde RBAC kapisi yok | acik | `tests/rbac` kapisi yaz |
| R-12 | in-process cagiran kod RBAC'i atlar (tasarim siniri) | D | B1 | kabul | Belgelerde sinir olarak kalir |

## 6. Kapsam disi

- Cok kiracili (multi-tenant) izolasyon: tek veritabani = tek guven alani.
- Isletim sistemi seviyesinde saldirgan (root/admin): dosya sifrelemesi
  disinda savunma yok, olmasi da beklenmez.
- Yan kanal ile fiziksel erisim (bellek dump, DMA).
- Ag katmaninda DDoS: uygulama seviyesinde cozulmez.
- TLS sertifika yasam dongusu (CRL/OCSP, rotasyon) — `SERVER_HARDENING.md`
  kapsam disi listesiyle ayni.

## 7. Guncelleme kurali

Bir risk kapandiysa: satiri **silme**, `Durum` alanini `kapali` yap ve
kapatan kapiyi (`tests/...`) yaz. Yeni saldiri yuzeyi (yeni protokol
komutu, yeni SQL ifadesi, yeni dis bagimlilik) eklendiginde ayni commit'te
buraya satir ekle.

