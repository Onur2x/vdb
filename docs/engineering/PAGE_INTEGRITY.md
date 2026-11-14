# Sayfa / heap / freelist tutarlilik denetimi (Phase 4)

Bu belge `p4-page-index` kaleminin hangi kodla ve hangi kapıyla
kanıtlandığını kaydeder. Kapsam: V3 sayfa motorunun `Verify` denetimi ve
bozulma senaryolarına verdiği **açık** tepki.

## 1. Kapı

| Kapı | Dosya | Ne doğrular |
|---|---|---|
| `page_integrity` | `tests/page_integrity/page_integrity.lpr` | Bozuk sayfa/anahtar/tasma/freelist/baslik kesik dosyanın sessizce kabul edilmediğini (I0-I13) |

Kapı, sağlam bir yedek imajı alır; her senaryo için imajın bir **kopyasını**
bayt düzeyinde bozar. Beklenti iki türlüdür: ya açılış (open) açık hata
verir, ya da motor açılır ve `Verify` raporlu olarak reddeder. Hiçbir
senaryoda "sessiz kabul" kabul edilmez.

## 2. Denetim yolu

`IVdbBackend.Verify` (`VDbBackendApi.pas:226`) → `TVdbPageEngine.Verify`
(`VDbPageEngine.pas`). Denetim sırası:

1. Açık parti/işlem varsa reddedilir (onaysız durum doğrulanmaz).
2. Bekleyen WAL çerçeveleri checkpoint edilir; doğrulanan şey **diskteki**
   durumdur (salt-okunur oturumda WAL yazılmaz).
3. Freelist zinciri yürünür (`VerifyFreeList`): trunk döngüsü, aralık dışı
   girdi, yinelenen girdi, sayaç uyuşmazlığı.
4. Her sayfa: sihirli sayı, yapı + CRC (`PageVerify`), başlıktaki sayfa
   numarası, tip.
5. Heap sayfaları: hücre başlığı, yinelenen anahtar, taşma (OVF) bayrağı ve
   zincir yürüyüşü; zincir döngüsü, aralık dışı halka, birden fazla zincire
   ait taşma sayfası, eksik bayt.
6. Anahtar sayısı heap dizini ile karşılaştırılır.
7. Sahipsiz taşma sayfası denetimi (dosyadaki taşma sayfası sayısı =
   zincirlerde görülen sayfa sayısı).

## 3. Bu fazda bulunan ve kapatılan gerçek hata

**Freelist trunk sayfaları yanlış "bozuk" sayılıyordu.**

`Verify`'in sayfa taraması yalnızca boş sayfaları (freelist girdilerini)
atlıyordu. Trunk sayfaları ise `VDB_TRUNK_MAGIC`/kendi CRC düzenini taşır,
`VDB_PAGE_MAGIC` taşımaz. Sonuç: satır silinip sayfalar freelist'e
döndükten sonra `Verify` **"sayfa N taninmiyor"** diyerek sağlıklı bir
veritabanını bozuk ilan ediyordu (yanlış pozitif). Yedek/geri yükleme
kapılarında boş sayfa üretilmediği için görülmemişti.

Düzeltme (`VDbPageEngine.Verify`):

- Sayfa taramasında `FStore.IsTrunkPage(P)` ise sayfa atlanır ve
  `trunkPages` olarak sayılır (Zincir zaten adım 3'te doğrulandı).
- Bırakma (`Release`) artık sabit bir `cur` değişkeniyle yapılır; döngü
  değişkeni iç dalda artırıldığı için yanlış çerçevenin bırakılması
  (ikinci bir gerçek hata: `Release: sayfa 3 pinli degil`) engellenir.
- Rapor satırına `trunk=` alanı eklendi:
  `sayfa=%d serbest=%d heap=%d tasma=%d trunk=%d anahtar=%d lsn=%d`.

## 4. Kapı matrisi (I0-I13)

| No | Kontrol | Beklenen |
|---|---|---|
| I0 | 3 küçük + 1 taşma gerektiren büyük satır yazıldı, yedek alındı | imaj var, boyut > 0 |
| I1 | Temiz veritabanı `Verify` | true, rapor `sayfa=` ile başlar |
| I2 | Rapor `anahtar=` ve `lsn=` taşır | true |
| I3 | İmaj bağımsız açılıp `Verify` | true |
| I4 | Aynı sayfaya aynı hücre ikinci kez | açılış `yinelenen anahtar` |
| I5 | Gövde baytı XOR, CRC tazelenmez | açılış `sayfa N bozuk ... CRC tutmadi` |
| I6 | Sayfa sihirli sayısı bozulur | açılış `taninmiyor` |
| I7 | Heap sayfası OVERFLOW tipine çevrilir | `Verify`: `sahipsiz tasma sayfasi` |
| I8 | Taşma hücresinin uzunluğu +4000 | `Verify`: `tasma eksik N/M bayt` |
| I9 | Dosya yarım sayfa kesilir | açılış `dosya kesik` |
| I10 | Başlık (meta) baytı XOR | açılış `baslik sayfasi CRC tutmadi` |
| I11 | Boşaltılmış veritabanında trunk girdisi aralık dışı | `Verify`: `freelist girdisi aralik disi` |
| I12 | Aynı boşaltılmış imaj bozulmadan | `Verify` true (`trunk=` sayılır) |
| I13 | Temel imaj tüm senaryolardan sonra | `Verify` true (kopyalar kullanıldı) |

## 5. Kapsam dışı (dürüst sınır)

- **Ayrı indeks dosyası** (`VDbIdxFile`) bu kapıda kullanılmaz. Buradaki
  "indeks" heap anahtar dizini + freelist zinciridir. Ayrı indeks
  dosyasının kendi tutarlılık denetimi ayrı bir kalemdir.
- **B+Tree silme/rebalance** testleri Phase 6 (`p6-btree`) kapsamındadır.
- **Şifreli imajda** bozulma senaryoları bu kapıda koşulmaz (anahtar
  gerektirir); şifreli sayfa zarfı `crypto_*` kapılarında doğrulanır.
- **Eşzamanlı bozulma** (başka süreç yazarken) ve fsync hatası
  senaryoları `wal_crash` kapısının konusudur.
- Onarım (repair) aracı yoktur: denetim **reddeder**, sessizce onarmaz.

## 6. Yerel kanıt

- WSL x86_64 Linux / FPC 3.2.2: **15 kapı PASS**; `page_integrity`
  **14 PASS, 0 FAIL**.
- Windows FPC 3.2.4 (i386-win32), Git Bash: aynı kapı (bkz. `CI.md`).

## 7. İlgili flakiness düzeltmesi

`kv_wal` kapısının `k4_crc` senaryosu, CRC baytını **sabit** `$FF` ile
eziyordu; bayt zaten `$FF` ise kayıt sağlam kalıyor ve kapı yanlış
sonuç üretebiliyordu (ölçüldü: bir koşuda FAIL). Artık bayt XOR'lanır
(`XorPatchFile`), böylece bozulma her zaman gerçekleşir. Bu, release
gate'in "flaky testler kontrol altında" maddesine doğrudan katkıdır.
