# VDB V3 - Izolasyon ve Kilitleme Modeli

Bu belge `docs/engineering/STORAGE_AUDIT.md` icindeki **G3** boslugunu
kapatir: "izolasyon seviyeleri belgeli" maddesi bugune kadar **YOK**
isaretliydi. Kilit/izolasyon bilgisi daha once `LIMITS.md` (tek yazar
rezervasyonu, `BusyTimeoutMs`), `SERVER_HARDENING.md` (giris sinirlari) ve
kaynak koddaki yorumlara dagilmisti. Burada **tek yerde** toplanir.

Durus: **BETA CANDIDATE**. Bu belge bir SQL standardi uygunluk iddiasi
degildir; asagidaki her davranis koddan okunmus ve/veya kapilarla
olculmustur. Olculmeyen sey acikca "olculmedi" yazilir.

Ilgili belgeler: `docs/engineering/LIMITS.md` (sayisal sinirlar, tek
kaynak), `docs/engineering/RESOURCE_LIMITS.md` (kapi eslemesi),
`docs/engineering/STORAGE_AUDIT.md` bolum 6 (kilit envanteri),
`docs/engineering/NETWORK_SECURITY.md`, `docs/security/THREAT_MODEL.md`.

---

## 1. Kapsam ve temel varsayim

VDB **gomulu, tek dosya** bir veritabanidir. Kabul edilen varsayimlar:

- Ayni veritabani dosyasina erisen surecler **ayni makinededir**; dosya
  sistem kilidi (`LockFileEx` / `flock`) anlamli olmalidir.
- Paylasilan ag surucusu (SMB/NFS) uzerinden ayni dosyaya es zamanli yazim
  **desteklenmez ve olculmedi**.
- Bir oturumda ayni anda **en fazla 1 acik islem** vardir.
- Kilitler **isletim sistemi** kilitleridir; yalniz uygulama icindeki bir
  `Boolean` bayraga dayanmaz.

Bu modeli asan senaryolar (dagitik yazarlar, paylasilan ag dosyasi, cok
anahtarli kilit yoneticisi) bu belgenin kapsami disidir.

---

## 2. Kilit mimarisi

### 2.1 Dosya kilitleri

| Kilit | Nerede | Davranis |
|---|---|---|
| Paylasimli veri kilidi | `VDbPageStore.AcquireDataRead` | Coklu okuyucu ayni anda tutabilir |
| Dislali veri kilidi | `VDbPageStore.AcquireDataWrite` | Yazma ve checkpoint penceresinde alinir |
| Yazar rezervasyonu | `VDbPageStore.TryAcquireWriteHold` (`.gen` handle'i) | **Islem suresi boyunca** tutulur; yalnizca yazarlari siraya sokar, okuyuculari bloklamaz |
| Acilis kilidi | `AcquireWriteOpen` | Rezervasyonsuz, kisa kritik bolum |

Platform karsiliklari: Windows `LockFileEx`, Linux `flock`. macOS ayni POSIX
yolunu kullanir ama **macOS'ta hic kosulmadi** (bkz. bolum 10).

### 2.2 Kilit alma sirasi (belgeli)

Kilitlenmeyi onlemek icin sira **sabittir**:

```text
depo yazma kilidi (AcquireDataWrite)  ->  motor kilidi (FEngCs)
```

Ters sira (`FEngCs` -> `AcquireDataWrite`) bir yazarla kilitlenme uretir.
Bu kural commit, arka plan checkpoint (`RunBackgroundCheckpoint`) ve
`CommitBatch` icin aynidir; kodda yorumla kayitlidir
(`VDbBackendV3.pas` P-178 notu).

Ic ice kiralama derinlik sayaciyla (`FDataWriteDepth`, `FHoldDepth`)
korunur: ic `Release` dis kilidi birakmaz.

### 2.3 Tek surec optimizasyonu

Uygulama tek surec oldugunu biliyorsa `ExclusiveAccess := True` ile dosya
kilidi syscall'lari tamamen atlanir (`FExclusiveAccess`); bu durumda
siralama surec ici `MREW` kilidiyle yapilir. Bu bir **hiz** secenegidir,
guvenlik modelini degistirmez ama cok surecli kullanimda **kapatilmasi
gerekir**.

---

## 3. Islem yalitim seviyeleri

`SET TRANSACTION ISOLATION LEVEL ...` desteklenir (F-40).

| Seviye | Gorunurluk davranisi | Durum |
|---|---|---|
| `READ UNCOMMITTED` | Her cumle basinda yeni gorunurluk penceresi (READ COMMITTED gibi ele alinir) | Kabul edilir |
| `READ COMMITTED` | Her **cumle** basinda pencere ilerler; onceki cumlelerin gordugu satirlar degisebilir | Kabul edilir |
| `REPEATABLE READ` | **Varsayilan.** Islem basindaki goruntu (`StartGen`) sabittir | Varsayilan |
| `SERIALIZABLE` | Su an `REPEATABLE READ` ile **ayni** snapshot davranisi + tek global yazar kilidi | Kisitli |

**Durust sinir:** `SERIALIZABLE` bugun ayri bir protokol (SSI/predicate
locking) uygulamaz; tek yazar kilidi nedeniyle pratikte serilesen yazmalar
sunar ama bu bir serializability kaniti degildir. `READ UNCOMMITTED`
gercek `dirty read` sunmaz (kirli okuma yolu yoktur).

Varsayilan `REPEATABLE READ`, "islem basinda ne gorduysen onu gorursun"
demektir; **phantom** satirlar da sabitlenir cunku gorunurluk penceresi
`StartGen` ile kapanir.

### 3.1 Islem sinirlari (SQL katmani)

- Ic ice `BEGIN` **sessiz no-op**; ikinci bir islem katmani acilmaz.
- Islem yokken `COMMIT` / `ROLLBACK` **sessiz no-op** (SQL uyumlulugu icin
  bilincli; bkz. `RESOURCE_LIMITS.md` bolum 4).
- `SAVEPOINT` / `ROLLBACK TO` / `RELEASE` desteklenir; journal yalnizca o
  savepoint'ten sonra degisen anahtarlari tutar (200k satirlik partide
  her savepoint'te O(n) kopya onlenir).
- Bir oturumda **islem suresi siniri yoktur**; yalnizca bekleme siniri
  (`BusyTimeoutMs`) vardir. Uzun islem kaynak tutmaya devam eder.

---

## 4. Snapshot gorunurlugu (nasil calisir)

Acik islemi olan bir oturum, **basladigi andaki** goruntuyu okur. Baska bir
oturum commit ederken degisen anahtarlarin commit-sonrasi hali bir undo
alaninda tutulur (`TSnapRec`: `BaseGen`/`BaseValue` + `Posts[]`); okuyucu
kendi `StartGen`'ine gore eski degeri secer.

- Bellek penceresi = **en uzun ortak acik islem**; tum oturumlar kapaninca
  undo temizlenir (`FSets` bosalinca).
- Bir anahtarin `Base` degeri, ilk post-image'indan **onceki** degerdir ve
  motordan bir kez okunur.
- Islem disindaki okumalar (implicit/autocommit) her zaman **guncel**
  goruntuyu okur; snapshot maliyeti yalnizca acik islem varken olusur.

Sayfa katmaninda ayrica iki ek koruma vardir:

- **Meta sayfa LSN monotonlugu** (F13): bayat gorunumlu bir oturum dusuk
  LSN yazamaz; sayfa LSN'i meta LSN'inden buyukse okuma `EVdbPageStale`
  ile reddedilir.
- **Meta sayfa imaj karsilastirmasi**: tam kilit alindiktan sonra diskteki
  meta imaji son gorulenle karsilastirilir; farkliysa onbellek dusurulur ve
  yeniden yuklenir.

---

## 5. Cakisma denetimi: seri ve iyimser mod

### 5.1 Seri mod (varsayilan yol)

`BeginBatch` yazar rezervasyonunu **beklemeden** dener. Alinirsa islem
boyunca rezervasyon tutulur: ayni dosyaya yazacak baska surec
`BusyTimeoutMs` boyunca bekler, sure asilirsa kontrollu `mesgul`
(`EVdbPageStore`) alir. Veri kilidi yalnizca **commit penceresinde**
alinir; bu yuzden uzun bir islem **okuyuculari bloklamaz**.

### 5.2 Iyimser mod

Rezervasyon alinamazsa islem yine acilir (acik kalmaz):

- Yazimlar bellekte birikir, okuma goruntusu sabitlenir
  (`BeginDeferRefresh`), before-image zorunlu olur.
- Cakisma denetimi **commit aninda, anahtar bazinda** yapilir
  (`VerifyNoConflict`).
- Ayni anahtara iki surec yazdiysa commit **acik hatayla** durur:
  `yazma cakismasi: $<anahtar> baska bir oturum tarafindan degistirildi
  (islem geri alindi)` (`EVdbBackendV3`). **Veri kaybi yoktur**; islem geri
  alinir.
- Farkli anahtarlara yazan iki surec ikisi de commit eder; yazarlar artik
  **tamamen sirali degildir**.

Denetim anahtar bazinda ve **tablo kapsamli** nesil sayaclariyla yapilir
(`ReadGenScope`): baska bir tabloya yapilan commit ilgisiz islemi
durdurmaz. Kapsam bilinmiyorsa konservatif olarak global sayac kullanilir
(fazla cakisma uretebilir, kacirmaz).

Okuma kumesi izleme ust siniri `RYENI_MAX_READS = 4096` anahtardir; asilirsa
denetim konservatif esige duser (pencere yine kapanir, anahtar hassasiyeti
kaybolur).

---

## 6. Okuyucular, salt-okunur oturumlar ve sunucu

- **Coklu okuyucu** ayni anda acik kalabilir (paylasimli kilit).
- **Iki yazar oturumu ayni anda acilabilir** (MP4). "Ikinci yazar
  reddedilir" **yanlis** bir beklentidir; dogru iddia "es zamanli yazarlar
  serilestirilir / anahtar bazinda cakisma acik hatayla reddedilir"dir.
- **Salt-okunur oturum** (`CreateReadOnly`) yazmayi acikca reddeder (MP9)
  ve `.gen` dosyasini **olusturmaz/yazmaz** (yalniz okur).
- **Sunucu (PG wire):** `MaxConns` 64 (ayar 1..4096); tavan asilirsa yeni
  baglanti `kapasite dolu` alip kapanir, mevcutlar calismaya devam eder.
  Giris sinirlamasi **kullanici basina + toplam** sayaclarla calisir;
  **IP basina** sinir yoktur. Kimlik dogrulama SCRAM-SHA-256'dir.
- Sunucu, es zamanli yazarlari **kendi basina** serbestlestirmez; dosya
  rezervasyonu ve commit cakisma denetimi aynen gecerlidir. Ag uzerinden
  cok yazarli yuksek cakisma gecikmesi **olculmedi**.

---

## 7. Kilit birakma ve cokme

- Normal `Close` sirasi tum handle ve kilitleri birakir.
- Surec olumu (`SIGKILL` / `TerminateProcess`) **kalici kilit birakmaz**:
  isletim sistemi kilitleri handle kapaninca duser (MP7).
- Onaylanmis commit'ler olum sonrasi korunur (MP7: `COUNT` 110, `VERIFY`
  temiz); baska surec hemen yazip kapatabilir (MP8), kurtarma dongusu yoktur.
- Kilit hatasi **sessiz yutulmaz**: `VDB_SOCK_INVALID` / istisna olarak
  yuzeye cikar.
- **Deadlock tespiti YOK.** Tek yazar kilidi ve sabit kilit sirasi nedeniyle
  deadlock **beklenmez**; ama bir tespit mekanizmasi da yoktur. Ileride cok
  anahtarli kilitleme eklenirse bu madde yeniden acilmalidir.

---

## 8. Kanit: kapilar

| Kapi | Ne kanitlar | Sonuc |
|---|---|---|
| `multiproc` | Iki **gercek OS sureci**: MP1/MP10 tek dosya, MP2/MP3 coklu okuyucu, MP4 iki yazar oturumu, MP5 es zamanli yazar + bayat onbellek tazeleme, MP6 yeniden acilis, MP7 `SIGKILL` sonrasi durabilite + kilit, MP8 olum sonrasi yeniden yazma, MP9 salt-okunur reddi | 17 / 0 |
| `multi_writer` | Ayni dosyada iki oturum: WAL LSN kesin artan, yan dosyalar ikinci kapanistan sag cikar, kendi satirlari korunur, 12/12 durabil, backup+restore 18/18 | 12 / 0 |
| `txn_limit` | Yazar cakismasi ve sayfa sayaci gerilemesi; yeniden acilis 578 satir + `VERIFY` | 18 / 0 |
| `crash_points` | Deterministik cokme enjeksiyonu + gercek surec olumu (7-9) ve WAL budama (10) | 24 / 0 |
| `auth_throttle` | Sunucu giris sinirlama: esik, kilit, pencere, `AuthReset`, monotonik saat (F-20) | 16 / 0 |
| `server_failure` | Baglanti kapasitesi ve hata yollari | 16 / 0 |

Sonuclar iki platformda aynidir (Windows 42 / Linux 43 kapi, 0 FAIL);
ayrinti `docs/engineering/CI.md` run log'larindadir.

---

## 9. Bilincli olarak YOK olanlar

Bunlar kusur degil, kayitli sinirdir; kapasite/uyumluluk planlamasinda
bilinmelidir:

- **MVCC / cok surumlu sayfa duzeni**: gorunurluk undo penceresiyle
  saglanir; sayfalar tek surumludur, eski surumleri okuyan uzun islemler
  bellekte tutulur.
- **Satir/aralik kilitleri, `SELECT ... FOR UPDATE`**: yoktur; yazma
  cakismasi commit aninda anahtar bazinda yakalanir.
- **`SERIALIZABLE` icin SSI (predicate locking)**: yoktur.
- **Deadlock tespiti / kurban secimi**: yoktur.
- **Islem suresi zaman asimi**: yoktur; yalnizca bekleme siniri vardir.
- **Dagitik / ag paylasimli dosya uzerinde cok yazar**: desteklenmez.
- **mTLS, CRL/OCSP, IP basina hiz siniri**: ag katmaninda yoktur
  (`NETWORK_SECURITY.md` bolum 3).

---

## 10. Olculmeyenler ve acik riskler

Durust sinirlar; bunlar **kapatilmis degildir**.

1. **macOS kilit davranisi olculmedi.** POSIX `flock` yolu kullanilir ama
   macOS'ta ne derleme ne kapi kosumu yapildi.
2. **ARM64 / buyuk-endian olculmedi** (bkz. `V3_ADVANCED_HARDENING_REPORT.md`
   bolum H).
3. **Yuksek cakisma gecikmesi olculmedi.** Cok yazarli, ayni anahtara
   yuksek oranda cakisan yukte bekleme/geri alma gecikmesi olculmedi.
4. **Uzun islem + bellek.** En uzun ortak acik islem undo penceresini
   belirler; cok uzun islemlerde bellek buyumesi olculmedi (soak 25 sn,
   gercek 1h/6h/24h kosulmadi).
5. **Paylasilan ag dosyasi** (SMB/NFS) uzerinde kilit semantigi
   desteklenmez ve olculmedi.
6. **`SERIALIZABLE` gercek serializability kaniti sunmaz** (bolum 3).
7. **Sunucu uzerinden cok yazarli soak** kosulmadi.

---

## 11. Degisiklik yaparken uyulacak kural

Kilit veya izolasyon davranisi degisirse:

1. Bu belge ve `STORAGE_AUDIT.md` bolum 6 guncellenir.
2. `tests/multiproc` / `multi_writer` / `txn_limit` kapilarindan en az
   biri yeni davranisi **olcen** bir kontrol kazanir; kapi zayiflatilmaz.
3. Kilit alma sirasi degisiyorsa once deadlock analizi yapilir ve
   `VDbBackendV3`/`VDbPageStore` yorumlari guncellenir.
4. `CHANGELOG.md` ve `docs/engineering/CI.md` run log'u guncellenir.
5. Iki platformda tam kapi seti yesil olmadan degisiklik "tamam" sayilmaz.
