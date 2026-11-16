# Disk tabanlı B+Tree indeks tasarımı

Durum: **tasarım + mevcut durum ölçümü**. Bu belge bir vaat değil, bugünkü
davranışın dürüst tablosu ve ileride yapılacak işin sınırlarıdır.

Kapılar: `tests/btree_disk` (bağımsız sayfa biçimi, 78 kontrol),
`tests/sql_index_scale` (bu belgedeki ölçümler).

## 1. Bugün indeks nerede duruyor

| Katman | Bugünkü gerçek |
|---|---|
| Tablo satırları | 4 KB sayfa yığınında, `.odb` dosyasında (v5 biçimi) |
| Birincil anahtar (`_pkey`) | Sayfa yığınının anahtar→(sayfa, slot) araması; `PK` sorgusu `Index Scan using t_pkey on t` planı üretir |
| İkincil indeksler (`CREATE INDEX`) | **Bellekte**: `TVTableDb.FMemIdx: TDictionary<Int64, TIdxEntries>` — indeks başına sıralı tek dizi, satır başına `TIdxEntry(Key, Pk, Cov)` yani **üç Delphi string'i** |
| İndeks yardımcı dosyası | `.odb.idx` (`VDbIdxFile.pas`) — yığının anahtar→(sayfa,slot) kopyası; **asla veri kaynağı değildir**, bozuksa sessizce yok sayılır ve tam tarama ile yeniden kurulur |
| Disk B+Tree | `VDbBTreeDisk.pas` (v3.46) **vardır ve kapılıdır**, ama **v5 motor dosya biçimine bağlı DEĞİLDİR** |
| `VDbBTree` | Bellek içi B+Tree (yığın sayfa dizini/yardımcı yapılar); disk indeksi değildir |

Sonuç: ikincil indeksli bir sorgu diski indeksle taramaz; indeks tamamen
RAM'de kuruludur. `Index Only Scan using ix_t_v` planı bunu gizlemez, çünkü
plan adı yalnız "indeks kullanıldı" der, indeksin nerede durduğunu söylemez.

## 2. Bellek ve yeniden kurma maliyeti

- Kurulum: `BuildOneIndex` = tam tablo taraması + sıralama + skip list +
  (varsa) UNIQUE `value→pk` sözlüğü. `RebuildIndexes` bunu her geçerli
  indeks için yapar.
- Tetikleyiciler: ilk okuma (tembel), DDL/ALTER sonrası, `REINDEX`, ve
  `.odb.idx` reddedildiğinde tam tarama.
- RAM: satır başına indeks başına 3 string + kayıt/sözlük yükü. 1M satırlık
  tek indeks, ölçülen değerle birlikte `tests/sql_index_scale` raporunda
  `OLCUM` satırı olarak yazılır; bu belge ölçülen sayıyı §6'da taşır.
- Reopen: indeks bellekte olduğu için yeniden açılışta **yeniden kurulur**
  (yani açılış maliyeti tablo boyuyla büyür). `RebuildIndexes` çağrılmadığı
  sürece ilk indeksli sorgu bu maliyeti öder.

## 3. Tasarım: disk indeksi (ileride, ayrı iş)

Aşağısı bugünkü v5 biçimine dokunmadan **eklenebilecek** bir tasarımdır.
Bugün uygulanmış değildir; uygulanması ayrı bir sürüm ve ayrı bir kapı ister.

### 3.1 Sayfa düzeni

`VDbBTreeDisk.pas` ile aynı iskelet:

| Alan | Boyut |
|---|---|
| Sayfa | 4096 B |
| Başlık | 32 B: `PageNo:LongWord`, `Kind:Byte` (1 iç / 2 yaprak / 3 meta), `Level:Byte`, `NKeys:Word`, `Flags:LongWord`, `Crc:LongWord`, 12 B yedek |
| Hücre (yaprak) | 16 B: `Key:QWord` + `Val:QWord` |
| Hücre (iç) | 12 B: `Key:QWord` + `Child:LongWord`; hücre 0'ın anahtarı kullanılmaz = en sol çocuk |
| Slot | 4 B `(Off:Word, Len:Word)`, hücreler sayfa sonundan geriye paketlenir |
| Meta | 32 B kayıt: `Magic`, `Ver`, `PageSize`, `Seq:Int64`, `Root`, `PageCount`, `Height`, `NKeys` |

İki A/B meta sayfası; geçerli (CRC doğru) ve **en büyük `Seq`** kazanır.

### 3.2 Anahtar / değer işaretçisi

İkincil indeks için değer = birincil anahtar (QWord) ya da doğrudan
`(PageNo:LongWord, Slot:Word)` fiziksel adres. Fiziksel adres seçilirse
VACUUM/compact sonrası tüm indeksin yeniden yazılması gerekir; bu yüzden
**önerilen**: değer = birincil anahtar, satır erişimi yığın `_pkey`
aramasıyla. Bu, indeks ile yığın arasında tek yönlü bağımlılık bırakır ve
compact'ı indeks açısından nötr yapar.

### 3.3 Bölme (split)

- Yaprak dolarsa ortadan ikiye bölünür; ortanca anahtar iç sayfaya kopyalanır
  (yaprakta kalır, B+Tree kuralı).
- İç sayfa dolarsa ortanca anahtar yukarı taşınır (iç sayfada kalmaz).
- Kök bölünürse yeni kök bir seviye yukarıda oluşur, yükseklik +1.

### 3.4 Birleştirme / yeniden dağıtma

Bugünkü `VDbBTreeDisk` **yalnız boşalan sayfayı ayırır**; birleştirme ve
yeniden dağıtma yoktur. Sonuç: silme sonrası doluluk düşer, ölçülen yaprak
doluluk ~%65. Disk indeksinde bu kabul edilebilir bir başlangıçtır; tam
birleştirme VACUUM benzeri ayrı bir bakım işi olarak planlanmalıdır.

### 3.5 WAL entegrasyonu

İki seçenek:

1. **Fiziksel WAL**: sayfa değişiklikleri WAL'a `(PageNo, offset, bytes)`
   olarak yazılır. Mevcut `VDbPageWal` buna yakındır; indeks sayfaları da
   aynı WAL'a girerse kurtarma tek düzlemde kalır.
2. **Gölge sayfalama (shadow paging)**: `VDbBTreeDisk`'in bugünkü modeli.
   Sayfa yerinde güncellenmez, değişen sayfalar yeni numaralara kopyalanır,
   meta en son yazılır = commit noktası. WAL gerekmez; çökme öncesi meta
   yazılmadıysa önceki ağaç bayt bayt aynıdır, ulaşılamayan sayfalar açılışta
   serbest kalır.

v5 motoru WAL tabanlı olduğu için **birinci seçenek** format bütünlüğü
açısından daha az sürprizlidir; gölge sayfalama ise bağımsız bileşende
kanıtlanmıştır (yırtık meta, çökme noktası, CRC testleri geçer). Karar
verilmeden önce ölçülmesi gereken: gölge sayfalamanın yazma çoğaltma
maliyeti (her commit'te kök yolu kadar sayfa) ve WAL'ın checkpoint baskısı.

### 3.6 Çökme kurtarma

- Gölge sayfalama: meta A/B + CRC yeterlidir; kurtarma "en büyük geçerli
  `Seq`" seçimidir. `tests/btree_disk` BD13/BD14 bunu iki platformda ölçer.
- WAL: yeniden oynatma + checkpoint; `tests/wal_crash`, `tests/crash_points`
  ile aynı disipline girer.

### 3.7 Önbellek

Disk indeksinde sayfa önbelleği zorunludur (yoksa her düğüm ziyareti bir
okuma sistem çağrısıdır). Önerilen: sabit boyutlu LRU, `VDB_MAX_IDX_CACHE`
sayfa (varsayılan 256 sayfa = 1 MB), `ecLimit` ile değil sabit kapasiteyle —
önbellek dolunca en eski atılır, hata değil.

### 3.8 Kilitleme ve eşzamanlılık

- Tek yazar / çok okur: mevcut motor modeli.
- İndeks yazma yolu tablo kilidi altında; okuma yolu kilit paylaşımlı.
- `CREATE INDEX CONCURRENTLY` benzeri çevrimdışı kurulum ileride ayrı iş.

### 3.9 Yeniden kurma ve biçim sürümleme

- `REINDEX` disk indeksini sıfırdan kurar (yeni sayfa numaraları, yeni meta).
- Biçim sürümü meta kaydındaki `Ver` alanındadır; bilinmeyen sürüm
  `EBtdError` ile reddedilir (sessizce yeni ağaç kurmak yasak —
  `tests/btree_disk` BD18 bunu ölçer).
- Geriye uyum: v5 `.odb` dosyası **değişmez**. İndeks ayrı bir dosyada
  (`.odb.bdx`) durur; yoksa/bozuksa yığın taramasıyla yeniden kurulur, yani
  eski dosyalar indekssiz de açılır.

### 3.10 Ölçüm planı (uygulama öncesi/sonrası)

| Ölçüm | Bugün | Disk indeksle beklenen |
|---|---|---|
| 1M satır `CREATE INDEX` | tam tarama + sıralama, RAM'de | tam tarama + yazma |
| İndeksli nokta araması | RAM araması (hızlı, RAM'e bağlı) | 1-3 sayfa okuma |
| 1M indeks RAM maliyeti | satır başına 3 string | ~sabit önbellek |
| Açılış/reopen | indeks yeniden kurulur | meta okunur, kurulum yok |
| `.odb.idx` yeniden kurulum | tam tarama | geçerliyse gerekmez |

## 4. Bugünkü sınır: `VDbBTreeDisk` bağlı değil

`VDbBTreeDisk.pas` gerçek bir disk B+Tree'dir: 4096 B sayfa, CRC'li başlık,
gölge sayfalama, A/B meta, yırtık meta geri dönüşü, çökme noktasında önceki
ağacın tam okunması, CRC/yaşamsal bozulma tespiti, sayfa geri kazanımı
(`tests/btree_disk`, BD1-BD18, 78 kontrol, iki platformda aynı).

Ama:

- v5 motor dosya biçimine **bağlı değildir**; motor onu hiç çağırmaz.
- WAL/kurtarma ile entegre değildir.
- İkincil indeksler hâlâ bellekteki `FMemIdx` dizileridir.
- Birleştirme/yeniden dağıtma yoktur.

Dolayısıyla "VDB disk indeksi kullanıyor" cümlesi bugün **yanlıştır** ve
belgelerde kurulmaz.

## 5. Yasaklar

- Mevcut v5 dosya biçimini bozan, yetkisiz yeni bir disk indeks biçimi
  eklenmez. Biçim değişikliği ayrı sürüm + ayrı kapı + geri uyum planı ister.
- İndeks, veri kaynağı yapılmaz: indeks bozulursa veri kaybolmaz, indeks
  yeniden kurulur.
- Ölçülmemiş "hızlı/verimli" iddiası yazılmaz.

## 6. Ölçülen (tests/sql_index_scale)

Kapı: `tests/sql_index_scale` (IX1-IX20, 45 kontrol), iki platformda da
**45 PASS / 0 FAIL**.

Windows i386 (FPC 3.2.4) / Linux x86_64 (FPC 3.2.2):

| Ölçüm | Windows | Linux |
|---|---|---|
| 100k ekleme | 688 ms | 1028 ms |
| 100k `CREATE INDEX` (1000 grup) | 172 ms | 237 ms |
| 1M ekleme | 6625 ms | 11083 ms |
| 1M `CREATE INDEX ix_m_v` | 1016 ms | 1700 ms |
| 1M indeks kurulumu yığın deltası | 23.915 KB | 47.936 KB |
| 1M indeks satır başına (ölçülen) | 24 B | 49 B |
| 1M indeksli nokta okuma | 0 ms | 1 ms |
| Yeniden açılış sonrası ilk indeksli sorgu | 1203 ms | 1586 ms |
| `.odb.idx` yan dosyası, 100k | 1.083.868 B | 1.083.868 B |
| `.odb.idx` yan dosyası, 1M | 10.985.254 B | 10.985.254 B |

Plan doğrulaması (metin eşleşmesiyle, iki platformda aynı): PK araması
`Index Scan using t_pkey on t`; indekssiz kolon `Seq Scan on t (Filter ...)`;
`CREATE INDEX ix_t_w` sonrası eşitlik ve aralık sorguları
`Index Only Scan using ix_t_w on t`.

Dürüst yorum (ölçülen sayıların sınırı):

- Yığın deltası `TotalAllocated` farkıdır, RSS değildir. 100k kurulumunda
  Windows'ta **-104 KB** çıktı: ayırıcı, ekleme fazından kalan boş blokları
  yeniden kullandığı için delta negatif olabiliyor. Bu, "indeks bedava"
  demek değil — sayı bu ölçümde anlamsız, o yüzden 1M kademesindeki 24 B
  (i386) / 49 B (x86_64) satır başına değeri rapor ediyoruz. İki platformun
  farkı işaretçi/string başlığı boyutlarından gelir.
- Satır başına 24-49 B, `TIdxEntry` içindeki **üç Delphi string** (Key, Pk,
  Cov) + kayıt başlığıyla tutarlıdır. İndeks diske taşınırsa bu maliyet
  sayfa önbelleğiyle sınırlanır; bugün sınırsızdır.
- Yeniden açılış sonrası ilk indeksli sorgunun 1.2-1.6 s sürmesi, indeksin
  bellekte olduğunun doğrudan kanıtıdır: açılışta indeks yoktur, ilk sorgu
  tabloyu tarayıp indeksi kurar ve süre tam olarak o kurulumdur.
- `tests/single_file` varsayılanı değişmedi: `.idx` normalde kapanışta
  silinir. Bu kapı yan dosya davranışını ölçmek için `KeepIdxOnClose`
  seçeneğini açıkça açar; üretim varsayılanı hâlâ tek dosyadır.
- 10M kademesi koşmadı; indeks kapsama (covering) ayrıntısı ve eşzamanlı
  yazma ölçülmedi.

Bu bölümdeki her sayı kapı çıktısındaki `OLCUM` satırlarından alınmıştır;
ölçülmeyen bir şey tahminle yazılmaz.

