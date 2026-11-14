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
- **Disk tabanlı B+tree sayfa bölünmesi/birleşmesi** ayrı bir kalemdir.
- **Reindex/compaction komutu** yok: denge silme sırasında korunur,
  ayrı bir yeniden inşa adımı gerekmez (yine de `LoadSorted` yeniden
  yükleme yolu vardır).
- Performans taban çizgisi `p6-perf-baseline` kalemindedir; bu belge
  yalnızca yapısal doğruluk ve doluluk ölçer.
