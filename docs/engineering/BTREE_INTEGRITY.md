# B+Tree silme / denge / doluluk denetimi (Phase 6)

Bu belge `p6-btree` kaleminin hangi kodla ve hangi kapıyla kanıtlandığını
kaydeder. Kapsam: bellekteki sıralı indeks `TVDbBTree` (`VDbBTree.pas`).

## 1. Kapı

| Kapı | Dosya | Ne doğrular |
|---|---|---|
| `btree_integrity` | `tests/btree_integrity/btree_integrity.lpr` | Silme sonrası yapısal sağlamlık, minimum doluluk, yaprak zinciri Next/Prev, tarama yolları (152 kontrol) |

Kapı küçük `FMaxKeys` değerleriyle (4, 5, 8) bölünme/birleşme sınırlarını
zorlar; 257 ve 400 girdilik kümelerle yükleme, tek tek silme, karışık
ekleme/silme ve yoğunluk senaryolarını koşar. Her adımda
`CheckInvariants` çalışır.

## 2. Değişen davranış (önce / sonra)

**Önce:** `DeleteRec` yalnızca girdiyi diziden çıkarıyordu; hiçbir
yeniden dengeleme yoktu. Bir yaprağın son girdisi silinince o yaprak
**boş** kalıyor, kardeşleri az doluluğa düşüyor, ağaç yükseklik ve yaprak
sayısı bakımından gereksiz büyüyordu. Kod kanıtı: eski `DeleteRec`
gövdesinde ne rotate ne merge vardı; `Next` dışında yaprak bağlantısı
(`Prev`) da yoktu.

**Sonra (`v4.1`):**

- Her üst düzeyde, silinen çocuk minimumun altına düştüyse
  `RebalanceChild` çağrılır:
  1. sol/sağ kardeşten **ödünç alma** (`BorrowLeft` / `BorrowRight`),
  2. ikisi de doluysa ayırıcıyı aşağı indirip **birleştirme** (`MergeAt`).
- `Prev` alanı eklendi; yaprak birleştirmesinde zincir yerinde onarılır
  (`L.Next := R.Next; if R.Next <> nil then R.Next.Prev := L`).
- Kök ayırıcısını yitirip tek çocuğa indiğinde ağaç **çökertilir**
  (`Delete` içinde döngü): yükseklik küçülür, kök kuralı korunur.
- `LoadSorted` artık **eşit dağıtım** yapar (yapraklar ve iç düğümler):
  son düğüm "artık" olup minimumun altına düşmez.
- Minimum doluluk: yaprakta `FMaxKeys div 2`, iç düğümde
  `(FMaxKeys-1) div 2` anahtar. Birleştirme bu sınırlarla taşmaz
  (yaprak `2*(K div 2) <= K`, iç düğüm `2*((K-1) div 2)+1 <= K`).
- `CheckInvariants` güçlendirildi: boş yaprak reddi (kök hariç), minimum
  doluluk yürüyüşü (`MinWalk`), iç düğümde en az 2 çocuk, yaprak
  zincirinde `Prev` tutarlılığı, boş yaprakta `Entries[0]` okumama.
- Tanılama için `Height` ve `LeafCount` eklendi.

## 3. Dürüst sınır: eski kodda çökme yeniden üretilemedi

Eski `VDbBTree.pas` (HEAD `929348c`) ile ölçüm yapıldı: 40 girdi, `K=4`,
tamamı artan ve azalan sırada silindiğinde `CheckInvariants` **boş**
döndü ve çökme görülmedi (FPC'de aralık denetimi varsayılan kapalı
olduğu için boş dizi erişimi sessizce geçebiliyor). Bu nedenle burada
"eski kod çöküyordu" iddiası **kurulmadı**. Kanıtlanan şey yapısaldır:
eski silme yeniden dengelemiyordu ve bu yüzden boş/az dolu düğümler
ağaçta kalabiliyordu. Yeni kapı bunu **minimum doluluk** ve **Prev**
değişmezleriyle kilitler.

## 4. Kapı matrisi (özet)

`K ∈ {4, 5, 8}` için koşan senaryolar:

| Senaryo | Ne ölçer |
|---|---|
| `K<n>/asc`, `desc`, `rand` | `LoadSorted(257)` sonrası sırayla tam silme; her 3 adımda invariant, `Count` tutarlılığı |
| `K<n>/small` | 7 girdilik küçük ağaç (kök yaprak / tek seviye sınırı) |
| `K<n>/churn` | 200 anahtar karışık sırada eklenir; 25 adımda invariant; yinelenen ekleme `False`; `Find`/`LowerBound`/`RankBefore`/`CountRange`/`CollectRange` doğruluğu; sonra tam silme |
| `K<n>/mutate` | `LoadSorted` sonrası araya ekleme + yarısını silme |
| `K<n>/density` | 400 girdinin yarısı tohumlu rastgele silinir; yaprak doluluk oranı ve `All` sayısı |
| `K4/single` | Tek girdilik ağaç: silme kökü boşaltır, `Height = 1` kalır |
| boş ağaç | `Count=0`, `All=0`, `Delete=False`, invariant boş |

Ölçülen doluluk oranları (rastgele yarı silme sonrası):
`K=4 → 0.63`, `K=5 → 0.53`, `K=8 → 0.61`. Eşik `>= 0.20`.

Son durum: **152 PASS, 0 FAIL** (WSL x86_64 / FPC 3.2.2; Windows i386 /
FPC 3.2.4 aynı sayı).

## 5. Kapsam dışı (dürüst sınır)

- **Disk üzerindeki indeks dosyası** (`VDbIdxFile`) ve sayfa biçimi bu
  kapıda koşulmaz; buradaki ağaç bellekteki `TVDbBTree`'dir.
- **Eşzamanlı erişim** (birden çok iş parçacığı) kapsam dışıdır; ağaç
  çağıranın kilidi altında kullanılır (`TIdxSkip` sözleşmesi).
- **Disk tabanlı B+tree sayfa bölünmesi/birleşmesi** ayrı bir kalemdi;
  bağımsız bir uygulama §7'de ölçülüyor. Birleştirme/yeniden dağıtma hâlâ
  yoktur.
- **Reindex/compaction komutu** yok: denge silme sırasında korunur,
  ayrı bir yeniden inşa adımı gerekmez (yine de `LoadSorted` yeniden
  yükleme yolu vardır).
- Performans taban çizgisi `p6-perf-baseline` kalemindedir; bu belge
  yalnızca yapısal doğruluk ve doluluk ölçer.

## 6. Ölçek ölçümü (`btree_scale`, PHASE-25)

SKILL3 §13 kuralı: *"Ölçülebilir bir sorun olmadan spekülatif B+Tree
değişikliği yapma."* Bu yüzden `tests/btree_scale` **ağaç yapısını
değiştirmez**; yalnızca ölçer. Ölçüm sırasında `TVDbBTree`'de yapısal bir
kusur çıkmadı, bu yüzden ağaca müdahale edilmedi — ama kapı **iki gerçek
motor hatasını** yakaladı (aşağıda F17/F18) ve ikisi de aynı sürümde
düzeltildi.

| Ölçüm | Windows i386 / FPC 3.2.4 | Linux x86_64 / FPC 3.2.2 |
|---|---|---|
| 1.000.000 anahtar, karışık sırada ekleme | **8.203 ms** | **12.789 ms** |
| 100.000 anahtar (aynı yol) | **219 ms** | **281 ms** |
| Ölçek (işlem başına maliyet) | **3,75x** | **4,55x** |
| Yükseklik / yaprak / doluluk | **4** / **14.965** / **66/96** | aynı |
| `All()` / `Find` / `CountRange` / `RankBefore` | 1.000.000 artan, 8.000/8.000 bulundu, aralık ve sıra analitik beklentiyle aynı | aynı |
| 500.000 silme (her ikinci anahtar) | 1.265 ms, `Count=500000`, yükseklik 4'te kalır | 1.466 ms, aynı sonuç |
| Yeniden ekleme sonrası yaprak sayısı | 14.965 → 14.979 (**1,00x**) — churn sonrası yaprak parçalanması yok | aynı |

**Toplam süre oranı (35-46x) tek başına yanıltıcıdır** ve bu yüzden eşik
olarak kullanılmaz: 1M anahtar önbellek dışına taşar, işlem başına maliyet
3,75x (Windows) / 4,55x (Linux) büyür. Karesel bir ağaçta işlem başına
maliyet veriyle doğru orantılı olurdu (10x veride ~10x), bu yüzden kapı
bunu ölçer. Sayılar mutlak bir garanti değil, bu makinelerdeki
reproducible ölçümdür; başka donanımda farklı çıkar.

### Diskte ölçek + VACUUM

| Adım | Sonuç (iki platformda da aynı) |
|---|---|
| 6.000 satır yaz | 1.449.984 bayt mantıksal / 1.601.536 bayt fiziksel |
| %90 sil (600 satır kalır) | Dosya **küçülmez** (belgelenen davranış; `GetDeadBytes` yalnız freelist sayfalarını sayar, `oluBayt=0`) |
| `VACUUM` | 1.601.536 → **151.552** bayt (**%90 kazanç**) |
| VACUUM sonrası | `COUNT(*)` = 600 birebir, kalan değerler doğru |
| VACUUM sonrası 600 satır daha ekle | 294.912 bayt (tavan 1.449.984) — dosya şişmez |
| Yeniden açılış + `VERIFY` | Temiz (`sayfa=72 serbest=0 heap=71 tasma=0 trunk=0 anahtar=1201 lsn=5`) |

### Bu ölçümün yakaladığı iki motor hatası (v3.43)

- **F17 — Unix'te her açılış bir dosya tanıtıcısı sızdırıyordu.** `VDbSync.VDbOpenStreamNoFlock`
  fd'yi `FpOpen` ile açıp `THandleStream`'e sarıyordu; FPC'nin
  `THandleStream.Destroy` handle'ı **kapatmaz**. Windows'ta belirti yok;
  WSL `/mnt/d` (9p) üzerinde açık handle'lı bir dosyanın `rename`'i `True`
  döner ama tembel uygulanır (dosya iki ad altında da görünmez). Bu yüzden
  VACUUM'un `.bak` değişimi yeni dosyayı açamadı, eskisini geri koydu ve
  **VACUUM yer kazanmadı** (BS11 `eski=1601536 yeni=1449984`). Düzeltme:
  `TVDbFdStream = class(THandleStream)` + `Destroy`'da `FpClose(Handle)`.
- **F18 — başarısız dosya değiştirme sessizce başarılı görünüyordu.**
  `SwapDbFileWith`'in dış `except`'i hatayı yutuyordu; `.bak` geri kurulumu
  başarısız olsa bile `Compact`/`RESTORE`/`REKEY` normal dönüyor ve VACUUM
  sahte `kazanç` sayıları basıyordu. Artık açık hata fırlatılır, hata
  yukarı taşınır ve backend `FEng=nil` ile kilitsiz bırakılmaz.

**Dürüst sınır:** diskteki ölçüm tablo satırlarının kullandığı bellekteki
ağaç (`VDbTable` içindeki `TVDbBTree`) üzerindendir. Ayrı bir disk
üzerindeki B+tree sayfa biçimi bu ölçümün kapsamı dışındaydı; artık
bağımsız bir uygulaması vardır ve §7'de ölçülür, **ama v5 motor dosya
biçimine bağlı değildir**. VACUUM'un geri kazanması sayfa deposunun
(heap) yeniden yazılmasıyla olur, indeks sayfası bölünmesiyle değil.

## 7. Ayrı disk sayfa biçimi (`VDbBTreeDisk`, PHASE-27 / v3.46)

Bu bölüm §5'teki kalemi kapatır — **ama tam olarak değil**: ayrı bir disk
sayfa biçimi artık vardır ve kapıdan geçer, yine de **v5 motor dosya
biçimine bağlı değildir**.

### Ne yapıldı

`VDbBTreeDisk.pas` kendi başına açılıp doğrulanabilen bir B+Tree sayfa
biçimi uygular; kapısı `tests/btree_disk` (BD1-BD18).

| Kalem | Değer |
|---|---|
| Sayfa boyu | 4096 bayt; 32 bayt başlık (PageNo, Kind, Level, NKeys, Flags, sayfa CRC'si) |
| Meta | iki kopya (sayfa 0 ve 1); en yüksek `Seq` + geçerli CRC kazanır |
| Yaprak hücresi | 16 bayt: `Key:QWord` + `Val:QWord` |
| İç hücre | 12 bayt: `Key:QWord` + `Child:LongWord`; hücre 0 = en sol çocuk |
| Yönlendirme | "`Key_i <= K` olan en büyük i" |
| Atomiklik | gölge sayfalama: sayfa yerinde güncellenmez, kökten yaprağa yol yeni sayfalara kopyalanır, **meta en son yazılır** (commit noktası) |
| Silme | tembel: anahtar çıkar, yalnızca boşalan sayfa düşürülür; yükseklik yalnızca kök tek çocuğa inince azalır |

### Ölçülen (iki platformda aynı: 78 PASS, 0 FAIL)

| Kontrol | Sonuç |
|---|---|
| Ekle/oku/güncelle, `Walk` sırası | 1.000 anahtar, kesin artan sıra, `count` birebir |
| Yeniden açılış | 1.000 anahtar + `Verify` temiz; dosya **küçülmez** (57.344 → 57.344 bayt) |
| Silme + yeniden açılış | 500 anahtar kalır, silinenler yok, `Verify` temiz |
| Sıralı/karışık yükleme | azalan 2.000 ve karışık 3.000/6.000 anahtar; hepsi bulunur |
| `NextAfter` alt-sınır taraması | 6.000 sorgu sıralı listeyle **birebir** |
| Bölünme ağırlıklı büyüme | 6.000 anahtar, yükseklik 2, 36 yaprak |
| Churn (sil + yeniden ekle) doluluk | `yaprak=36 hucre=6000 doluluk=96000/147456` (~%65) |
| Sayfa geri kazanımı | hepsi silinip yeniden eklenince sayfa sayısı 75 → 75 (**şişme yok**) |
| Yırtık meta | yeni meta sayfası bozulunca **önceki ağaç** aynen açılır (300 anahtar; yeni 300 anahtar görünmez) |
| Çökme noktası | meta yazımından **hemen önce** alınan kopya önceki ağacı tam okur (200 anahtar) — veri kaybı yok |
| Yalnız-CRC bozulması | `Verify` FAIL; okuma yolu çalışmaya devam eder (500/500 bulunur) |
| Yapısal bozulma | `Verify` FAIL; okuma yolu **kontrollü `EBtdError`** atar, erişim ihlali yok |
| Kesik dosya (<2 sayfa) | sessizce yeni ağaç **kurulmaz**, `EBtdError` |

### Bu kapının bulduğu üç gerçek kusur

1. **Windows'ta her açılış ağacı siliyordu.** `VDbOpenStreamNoFlock(ad, False, True)`
   Windows'ta `fmCreate`'e karşılık gelir ve dosyayı **sıfırlar** (Unix'te
   `O_CREAT` sıfırlamaz). Birim artık `FileExists` ile ayırır
   (`VDbPageStore` ile aynı desen). Kapı olmadan bu sessiz veri kaybıydı.
2. **Kurucu istisnasında çift serbest.** Yarım kurulmuş nesnede alanlar
   `nil`'e çekilmediği için FPC'nin otomatik yıkıcısı `FMap`'i ikinci kez
   serbest bırakıyordu (erişim ihlali). `FreeAndNil` + yıkıcıda `nil`
   kontrolü.
3. **`Verify` bozuk dosyada istisna sızdırıyordu.** Doğrulayıcı artık
   aralık dışı sayfayı bulgu olarak raporlar ve `False` döner.

### Dürüst sınır

- Birim **v5 motor dosya biçimine, WAL'a ve kurtarma yoluna bağlı
  değildir**; `VDbPageEngine`, `VDbTable` ve SQL yolu onu kullanmaz.
  Dolayısıyla v5 dosya biçimi ve kurtarma davranışı **değişmedi**.
- Tablo satırları hâlâ 4 KB sayfa yığını üzerinde, ikincil indeksler
  hâlâ bellekteki `TVDbBTree` üzerinde durur.
- Birleştirme/yeniden dağıtma yoktur; tembel silmenin doluluk maliyeti
  gizlenmez, kapı ölçer (~%65).
- Motora bağlanması ayrı bir iş kalemidir ve o gün ayrıca kapı + kurtarma
  çalışması gerekir. Bu belge o iddiayı taşımaz.

