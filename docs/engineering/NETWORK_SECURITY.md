# VDB V3 - Ag Guvenligi (PG Wire) Durumu

Bu belge SKILL4 Sprint F kapsaminda ag yuzeyinin **olculen** davranisini,
kapi sonuclarini, bilinen limitleri ve acik riskleri kaydeder. Ilgili
belgeler: `docs/engineering/SERVER_HARDENING.md`,
`docs/engineering/LIMITS.md`, `docs/security/THREAT_MODEL.md`,
`docs/engineering/CRYPTO_PROVIDER.md`.

Tarih: 2026-11-17. Durus: **BETA CANDIDATE**. Bu belge "internet'e
acilmaya hazir" iddiasi tasimaz.

---

## 1. Mevcut davranis (koddan)

| Konu | Varsayilan | Kaynak |
|---|---|---|
| TLS | **KAPALI** (opt-in). Sunucu sertifikasi `SetTlsFiles(cert, key)` ile verilir | `VDbPgWire.pas` (`FRequireTls := False`) |
| TLS zorunlulugu | `RequireTls` ozelligi ile acilir | `VDbPgWire.pas` |
| Istemci TLS | CA dosyasi **zorunlu**; dogrulamasiz baglanti yolu yok | `VDbTls.pas` (`FVerifyPeer := True`) |
| Kimlik dogrulama | En az bir kullanici tanimliysa **SCRAM-SHA-256**; parola sunucuda saklanmaz | `VDbPgWire.pas` (`P-180`) |
| Giris siniri | `AuthMaxFailures = 5`, pencere **60 sn**, kullanici basina + toplam | `VDbPgWire.pas` |
| Sinir saati | **Monotonik** `GetTickCount64` (duvar saati adimi kilidi uzatmaz/acmaz) | `F-20` duzeltmesi (v3.49) |
| Dinleme adresi | Cozumleme **fail-closed**; `--trust` modunda loopback disi adres **reddedilir** | `VdbResolveListenHost` |
| Es zamanli baglanti | 64 (ayar araligi 1..4096) | `VDbPgWire.pas` (`FMaxConns`) |
| Agdan gelen tek cerceve | 64 MiB (`VDBS_MAX_RECV_STR`) | `VDbNet.VdbRecvStr` |
| Protokol | PG wire uyumlu alt kume; TLS `SSLRequest` ile yukseltme | `VDbPgWire.pas` |

---

## 2. Kapi sonuclari (olculen)

| Kapi | Ne dogrular | Durum |
|---|---|---|
| `net_fuzz` | Bozuk/kesik/dusmanca girdiler: startup uzunlugu (70000, 2^31-1), kesik startup, 0/4/0xFFFFFFFF, bilinmeyen protokol, 512 rastgele bayt, gecerli startup + 30 rastgele mesaj, `Q` uzunlugu 64MB+1, kesik govde, NULsuz/kontrol baytli/bos sorgu, 20 ardisik `SSLRequest`, 40 kisa cop baglanti, 120 yinelemeli mutasyon, bozuk genisletilmis protokol + toparlanma, 4 is parcacigi x 8 eszamanli fuzz. Her senaryodan sonra **sunucu hala hizmet veriyor** mu diye ayrica kontrol edilir | PASS (N1a-N15) |
| `server_failure` | Sunucu hata yollari ve toparlanma | PASS |
| `server_harden` | Sertlestirme ayarlari ve reddetme davranisi | PASS |
| `auth_throttle` | Esik, kilit, pencere, `AuthReset`, buyuk/kucuk harf, bos kullanici; monotonik saat (`F-20`) | 16 / 0 |
| `tls_client` | Istemci TLS el sikismasi, CA zorunlulugu | Windows'ta SKIP; Linux'ta OpenSSL varsa kosar |

**Durust sinir**: `net_fuzz` deterministik ama **sinirli** bir senaryo
kumesidir (sabit seed, sabit uzunluklar). Genel bir protokol fuzz
kampanyasi veya surekli fuzz (AFL/libFuzzer tarzi) degildir.

---

## 3. Guvenlik kontrolleri - ne var, ne yok

**Var:**
- SCRAM-SHA-256 (parola sunucuda saklanmaz).
- Giris hiz siniri ve kilit; monotonik saat (duvar saati oynamasi etkisiz).
- TLS opt-in; istemci tarafinda CA zorunlu, dogrulamasiz baglanti yok.
- Dinleme adresi fail-closed; `--trust` modunda loopback disi red.
- Baglanti ve cerceve boyu tavanlari.
- Bozuk girdide baglanti duser, sunucu ayakta kalir (net_fuzz).

**YOK (bilincli olarak iddia edilmez):**
- **Karsilikli TLS (mTLS) / istemci sertifikasi** zorunlulugu.
- **CRL / OCSP** iptal denetimi.
- **Rate limit'in ag katmaninda** (IP basina) uygulanmasi; sinir
  kullanici basina ve toplam sayaclarla calisir.
- **DDoS / SYN flood** korumasi; isletim sistemi ve ters vekil isidir.
- **Denetim kaydi (audit log) butunlugu** ve merkezi toplama.
- **Sertifika pinleme** veya ALPN/SNI politikasi.

---

## 4. Acik riskler

1. **TLS varsayilan kapali.** Operator acmazsa trafik duz metindir; bu
   bilincli bir tercihtir (opt-in) ama yanlis yapilandirma riskidir.
2. **Sunucu soak'i kosulmadi.** `tests/soak` bir **gomulu motor**
   soak'idir; ag sunucusunun uzun sureli (1/6/24 saat) soak'i bu projede
   **kosulmadi** ve bu belge boyle bir iddia tasimaz.
3. **`net_fuzz` sabit seed** kullanir; yeni bir hata sinifi yakalanmayabilir.
4. **Tek yazar / tek dosya modeli** ag uzerinden es zamanli yazarlari
   serbestlestirmez; kilit modeli `LIMITS.md`'de tanimlidir.

---

## 5. Yapilan duzeltmeler

- **F-20** (v3.49): kimlik dogrulama cezasi duvar saatinden **monotonik**
  `GetTickCount64` milisaniyesine tasindi. Onceki kod saat geri alininca
  kilidi uzatiyor, ileri alininca sinirlamayi erken acabiliyordu. Ayarlar,
  API ve dis davranis aynidir; kapi 8/8 kosuda 16/16 PASS.
- TLS istemcisinde "dogrulamasiz baglanti yok" kurali CA dosyasi
  zorunlulugu ile koddan garanti edilir.

---

## 6. Gelecek is

1. Ag sunucusu icin ayri, uzun sureli soak (FD/thread/RAM) ve raporu.
2. `net_fuzz` icin rastgele seed + daha uzun kosu modu (CI'da kisa, gece
   kosusunda uzun).
3. mTLS ve CRL/OCSP degerlendirmesi (gereksinim netlesirse).
4. IP basina hiz siniri ve baglanti kabul backpressure'i.
