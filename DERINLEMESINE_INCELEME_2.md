# Derinlemesine Kod Incelemesi — Tur 2 (2026-11-06)

**Kapsam:** 6 eksen x 2 kisim — (1) Tur-1 iddialarinin tek tek dogrulanmasi
("halen gecerli mi?"), (2) yeni denetim.

**Inceleme ortami:** dal `v3`, inceleme `1fe0acf`'te basladi; eszamanli oturum
arada `d6f6f61` ("P-125: denetim bulgularindan guvenli duzeltmeler") commit
etti. 7 kaynak dosyada commit edilmemis calisma vardi; raporlar calisma
agacinin gorulen haline goredir, satir numaralari anlik goruntudur.

**Yontem:** salt okunur statik inceleme (derleme/çalıştırma yok). Her bulgu
dosya:satır kanitli; dogrulanamayan iddialar "supheli" isaretli. Performans
kazanclari "tahmin" etiketlidir, olcum yapilmamistir.

---

## 0. Yoneticinin ozeti

Tur-1 raporundaki **92 bulgu + 14 performans adayi** tek tek suclandi:
**68 gecerli, 17 duzeltildi/uygulandi, 10 kismen, 2 gecersiz.** Ana iddialarin
hicbiri yanlis tehis cikmadi; ote yandan Tur-1'in "olu kod/test yok" gibi
iki iddiasi yanlisti ve o turlar zaten Tur-1 raporunda guncellenmisti.

**KRITIK durum degismedi:** 6 krilik bulgunun 4'u (C-1, C-3, B-01, B-02,
D-1a) hala kodda. 2'si kismen giderildi (C-2) veya duzeltme sirasinda yeni bir
risk dogurdu (bkz. R2-D-1).

**Tur-2'nin en onemli yeni bulgusu — iki bagimsiz ajan ayni noktayi buldu:**
`VDbMM.pas:156-159` `SlabBits` kilitsiz RMW ile guncelleniyor. Bit kaybi →
slab "yabanci" sanilir → VirtualAlloc blogu FPC heap'ine `FreeMem` edilir →
**surec heap bozulmasi**. Sunucu (PgWire/SqlServer) cok baglantili yuk
profilinde tam tetikleyicidir.

**Ikinci kritik:** eszamanli oturumun commit edilmemis B-11 yamasi
(`PutRow`'da `FPrefixCacheName` yazimi) P-67 bayraklarini bayatlatiyor →
FK kaskadli UPDATE sonrasi INSERT'te `ApplyIdentity`/`VDbApplyGenerated`
atlanir → **kalici yanlis veri** (R2-D-1 / R2-E-3, iki ajan tarafindan
dogrulandi). Bu yama birlesmeden duzeltilmeli.

> **GUNCELLEME (2026-11-06):** Bu rapordaki guvenli bulgular P-126 ve P-127
> commit'lerinde uygulandi; kapatilan/kapatilmayan tum maddeler ve gerekceleri
> **EK-G — UYGULAMA KAYDI** bolumundedir. Kalan mimari maddeler (B-01, B-02,
> R2-B-2/B-3, C-1/C-3/C-16) bilincli olarak ertelendi.

---

## 1. Eski iddialarin kaderi — eksen eksen

| Eksen | Rapor | Toplam | Gecerli | Duzeltildi | Kismen | Gecersiz |
|---|---|---:|---:|---:|---:|---:|
| A Kaynak/bellek | r2_A | 13 | 8 | 2 | 2 | 0 |
| B Eszamanlilik | r2_B | 20 | 16 | 2 | 2 | 0 |
| C Cokme guvenligi | r2_C | 16 | 11 | 5 | (1'i kismen) | 0 |
| D Dogruluk | r2_D | 10 | 9 | 0 | 0 | 2* |
| E Performans adayi | r2_E | 14 | 5 | 5 | 4 | 0 |
| F Mimari/test | r2_F | 20 | 19 | 0 | 1 | 0 |

\* D-1b senaryosu ve "P-67 bayraklari hic okunmuyor" teşhisi gecersiz;
P-67 tamamlanmis ve bayraklar kosullu okunuyor (`VDbTable.pas:10583-10587`).

### 6 KRITIK Tur-1 bulgusunun bugunku durumu

| Bulgu | Durum | Kanit (guncel) |
|---|---|---|
| C-1 Checkpoint/Truncate onayli sayfalari budar | **GEÇERLİ** | Flush yalniz kirli sayfalari yazar (`VDbPageStore.pas:2743-2749`), Truncate filtresiz (`VDbPageWal.pas:960`) |
| C-2 VACUUM'da `.gen` silinmez, fsync atlanir | **KISMEN** | SwapDbFileWith durabil LSN'ini sifirliyor (`VDbBackendV3.pas:3925-3962`); silinip yeniden yaratilan DB'de `.gen` korunuyor (`VDbPageStore.pas:1845-1865`) → hala mumkun |
| C-3 temiz kurulum + MinLSN atlama → eski sayfa | **GEÇERLİ** | C-16 sayfa LSN damgasi dogrulamasi hala eklenmemis (`VDbPage.pas:65/196`) |
| B-01 ic ice taramada `FSnapMap` use-after-free | **GEÇERLİ** | `VDbBackendV3.pas:2579` ↔ `2035` |
| B-02 LockRead altinda lazy indeks yazimi | **GEÇERLİ** | `VDbTable.pas:9657-9813`; FTb tum baglantilar arasi paylasimli (`VDbSqlServer.pas:47-54,169`) |
| D-1a DDL-inside-batch bayat onbellek | **GEÇERLİ** | `MarkSchema` hala `ResetBatchTableCache` cagirmiyor; Path 2 `VDbTable.pas:10455-10458` |

### Duzeltildi/uygulandi (17)

`d6f6f61` (P-125) Tur-1'in guvenli alt kumesini kapatti: R-A-3, R-A-4 (kismen),
R-A-5 (kismen), R-A-11, B-14, B-18, C-6, C-13, C-14, C-15 ve performans
adaylari B3 (kismen), B4, B7, B9, B10, B11 (kismen), B13 (kismen).
Ayrintili dagilim EK-A…EK-F icinde.

### Performans adaylarinin kaderi (r2_E)

- **Uygulandi (5):** B4 sema onbellegi, B7 SplitStatements, B9 tetikleyici/RLS
  on-kontrolu, B10 plan-cache sizintisi, B13 cift denetim.
- **Kismen (4-5):** B3 (yalniz IndexOf), B8 (esleme tamam, O(n²) dizi 13
  noktada), B11 (prefix+HasIdxWork; tam okuma/EncodeRow kaldi), B13 (ValBuf).
- **Hala gecerli (5):** B1 PK varlik denetimi cift sondalama (0,8–1,8
  µs/satir — hala en buyuk kalem), B2 oto-PK ReadRow, B5 CheckConstraints,
  B6 CheckFk, B12 partial indeks. B14 (autocommit/fsync) degismedi.

---

## 2. Tur-2 yeni bulgulari (oncelik sirasiyla)

| # | Siddet | Bulgu | Yer |
|---|---|---|---|
| R2-A-1 = R2-B-1 | **KRITIK** | `SlabBits` kilitsiz RMW → bit kaybi → slab yanlis siniflandirma → `FreeMem` FPC heap'ine dusen VirtualAlloc blogu → heap bozulmasi | `VDbMM.pas:156-159` |
| R2-D-1 = R2-E-3 | **KRITIK** | Commit edilmemis B-11 yamasi `FPrefixCacheName`'i P-67 bayraklarini yeniden hesaplamadan yaziyor → FK kaskadli UPDATE/view insert sonrasi INSERT'te IDENTITY/GENERATED atlanir | `VDbTable.pas:7113-7117`, `10440-10458` |
| R2-F-1 | **KRITIK** | B-4 duzeltmesi D-1a'yi kapatmiyor: `MarkSchema` hala `FBatchTableDef/FBatchColMap/FBatchHas*` onbelleklerini sirfirlamiyor | `VDbTable.pas` MarkSchema |
| R2-B-2 | YUKSEK | `FBatchSet/FBatchSetSid` kilitsiz okunuyor → oturum yanlis write-set'i sahiplenir → oturumlar arasi yazma karismasi | `VDbBackendV3.pas:1495-1496` |
| R2-B-3 | YUKSEK | Paylasimli FT'de islem durumu (snapshot/`FDeferredRows`/CONCURRENTLY) cakismasi; `FT.BeginBatch` `RequireSoleTxn`siz → FK ihlali sessiz commit, baskasinin DDL rollback'i | `VDbTable.pas` / `VDbBackendV3.pas` |
| R2-C-1 | YUKSEK | Yarim VACUUM: SwapDbFile sonrasi istisnada `syncLsn` sirfirlanmiyor (MaybeAutoCompact yutuyor) → `CommitBatch` `AwaitDurable(eski LSN)` sonsuz fsync dongusu | `VDbBackendV3.pas:3033-3034,3868-3871`, `VDbPageEngine.pas:885-969` |
| R2-D-2 | YUKSEK | D-1a'nin indeks varyanti: batch icinde CREATE INDEX sonrasi bayat `T.Idx` → satir indekse islenmez, indeks taramasi satiri kacirir | `VDbTable.pas` |
| R2-F-6 | YUKSEK | Tum yeni hata yollari testsiz; ariza-enjeksiyon altyapisi yok | `tests/gates`, `tests/sql` |
| R2-A-5 | ORTA | VDbPool sayac kacak azalmasi | `VDbPool.pas` |
| R2-A-8 | ORTA | VDbCdc `FSeen` sinirsiz buyume | `VDbCdc.pas` |
| R2-A-11 | ORTA | PgWire portal bellegi Sync'te temizlenmiyor | `VDbPgWire.pas` |
| R2-A-12 | ORTA | COPY gecici dosya adi TOCTAR yarisi, capraz baglanti dosya silme | `VDbExecutor.pas` |
| R2-C-2 | ORTA | C-6 duzeltmesi ikincil fsync hatasini yutuyor → yanlis durum | `VDbPageEngine.pas` |
| R2-C-3 | ORTA | Basarisiz commit'in WAL kaydi geri alinmiyor → kurtarmada hayalet commit | `VDbPageWal.pas` |
| R2-D-3 | ORTA | FK kaskad commit/abort simetrisizligi | `VDbTable.pas` |
| R2-B-4 | ORTA | `FLastDirtyIdx` yanltilir | `VDbBackendV3.pas` |
| R2-B-5 | ORTA | VDbPool sahiplik/UAF | `VDbPool.pas` |

Performans yeni adaylari (Tahmin etiketli, olcum yok):

1. **R2-E-6** INSERT...SELECT satir dongusunde batch yok; satir basina
   AcquireWrite + kilit + otomatik-commit yazimi — 1–3 µs/satir
   (`VDbExecutor.pas:15586-15615` → `VDbBackendV3.pas:1930-1948`).
2. **R2-E-2** `FT.BeginBatch` donusumu her otomatik islemde SnapshotSchema
   (3 sozluk + tablo kopyalari) + tum onbellek gecersizlestirme —
   2–10 µs/statement (`VDbTable.pas:6126-6152, 6376-6393`).
3. **R2-E-1** `FireTriggers`'ta kullanilmayan tam `TTableDef` kopyasi (olu
   kod) — 0,1–0,4 µs/satir, sifir riskli (`VDbExecutor.pas:19412`).

---

## 3. Onerilen is sirasi (iki turun birlesimi)

1. **R2-A-1 / R2-B-1** (`VDbMM` SlabBits kilidi) — heap bozulmasi, sunucuda
   tetiklenir.
2. **R2-D-1** (commit edilmemis B-11 yamasi) — birlesmeden duzeltilmeli.
3. **D-1a + R2-F-1 + R2-D-2** (DDL-inside-batch bayat onbellek: sema,
   bayrak, indeks) — tek duzeltmede `MarkSchema` tum batch onbelleklerini
   sirfirlamali.
4. **B-01 + B-02 + R2-B-2 + R2-B-4** (paylasimli FTb/tarama durumu).
5. **C-1 + C-3 + C-16** (cok surecli kalici kayip; sayfa LSN damgasi
   dogrulamasi).
6. **R2-C-1** (yarim VACUUM → sonsuz fsync), **R2-C-3** (hayalet commit).
7. **R2-F-6** test altyapisi (ariza enjeksiyonu + DDL-in-batch + multi-row
   IDENTITY).
8. Performans: **B1** cift sondalama, sonra R2-E-6 / R2-E-2 / B2.

## 4. Eszamanli gelistirme uyari

Inceleme surerken baska oturum `d6f6f61`'i commit etti ve Tur-1 duzeltmelerinin
guvenli kismini uyguladi; calisma agacinda hala commit edilmemis yamalar var
(`VDbBackendV3.pas`, `VDbExecutor.pas`, `VDbSql.pas`, `VDbTable.pas`). R2-D-1
tam da o kirli dalgadaki yamadan doguyor. Bu rapordaki satir numaralari
`1fe0acf`–`d6f6f61` araligindaki goruntuyu yansitir.

---


---

# EK-A — alt ajan tam raporu

# R2-A — Kaynak Yaşam Döngüsü ve Bellek Sızıntısı II. Denetimi (salt-okunur)

- **Kapsam:** `D:\veritabani` (dal v3), FPC 3.2.4 / Delphi modu / i386-win32
- **Tarih:** 2026-11-06
- **İnceleme anındaki HEAD:** `d6f6f61` ("P-125: denetim bulgularindan guvenli duzeltmeler (R-A-3/4/5/11, ...)").
  Görev notunda `1fe0acf` yazıyordu; eşzamanlı commit'ler nedeniyle HEAD inceleme sırasında ilerlemiştir.
- **ÇALIŞMA AĞACI KİRLİ:** `VDbBackendV3.pas`, `VDbExecutor.pas`, `VDbSql.pas`, `VDbTable.pas`
  commit edilmemiş değişiklikler içerir (+475/−136). Tüm doğrulamalar çalışma ağacının GÜNCEL
  haline karşı yapılmıştır.
- **Yöntem:** Yalnız kaynak okuma (derleme/çalıştırma YAPILMADI; hiçbir dosya değiştirilmedi).
  Her bulgu dosya:satır ile kanıtlanır; doğrulanamayanlar `şüpheli` işaretlidir.
- **Odak (Kısım 2):** VDbMM.pas, VDbPool.pas, VDbCdc.pas, VDbDataSet.pas, VDbTimeTravel.pas,
  VDbPgWire.pas, VDbSqlServer.pas (tam okuma); VDbExecutor.pas (hedefli: BuildAsOfRows).

---

## KISIM 1 — Eski R-A raporundaki 13 iddianın doğrulanması

### Sonuç tablosu

| # | Eski iddia | Kader | Gerekçe (tek satır) | Kanıt (güncel) |
|---|---|---|---|---|
| R-A-1 | Recover tüm commit'li sayfa imgalarını bellekte tutar + O(n²) dedup | **GEÇERLİ** | `applied` hâlâ her commit'li sayfanın 4KB imajını tutar, `AddTo` hâlâ satır başına doğrusal dedup + `n+64` büyüme; içerik değişmemiş, yalnız satırlar kaymış. | `VDbPageWal.pas:735-758` (pending/applied + AddTo), `873-879`, `901-906` |
| R-A-2 | DoCommit'te pin/işlem/I/O kilidi exception yolunda bırakılmıyor | **GEÇERLİ** | `AppendFrame` exception'ında `Release`'e hâlâ ulaşılmaz; `EndTxn`/`EndIoWrite` yalnızca başarılı yolda; ayrıca `FWal.Commit` False dönerse `Exit(False)` de kilitleri bırakmaz (yeni ek kanıt). | `VDbPageEngine.pas:1009-1015`, `1021-1023`, `1037-1047`, `1063-1064`, `1075`, `1080` |
| R-A-3 | WriteOverflow exception'ında sahipsiz tasma sayfaları | **DÜZELTİLMİŞ** | `WriteOverflow` gövdesi try/except ile sarılmış; ortada hata olursa `curNo` serbest bırakılır, `FOvfPages` düşürülür, `FPageType` sıfırlanır ve `FreeOverflow(nextNo)` ile kısmi zincir geri alınır. | `VDbPageHeap.pas:459-510` (özellikle 492-509); ayrıca 481-485 yerinde geri alım |
| R-A-4 | ReadOverflow: çevrimsel zincir koruması yok + `len` doğrulanmadan Move | **KISMEN** | Sonsuz döngü `VDB_OVF_MAX_STEPS=1000000` adım sayacıyla giderilmiş (543-549) ve Move taşması `take := dl-4` + `Len-got` kırpımıyla giderilmiş (581-584); AMA `SetLength(Value, Len)` (530) hâlâ doğrulanmamış hücre `len` alanından (maske `$7FFFFFFF`) tek seferde dev tahsis açabilir ve aynı doğrulanmamış `len` deseni `ReadCellAt`'in tasma dışı yolunda sürüyor (914-916). | `VDbPageHeap.pas:48`, `530`, `543-549`, `581-584`, `899-916` |
| R-A-5 | FreeOverflow: çevrimsel zincir → sonsuz döngü / çift FreePage | **KISMEN** | Sonsuz döngü adım sayacıyla (607-608) giderilmiş; AMA çift serbest bırakma koruması hâlâ yok: çevrimsel zincirde sınır dolana kadar aynı sayfa ~1M kez `FreePage`'a gider (614) ve `FreePage` "zaten serbest mi" denetimi yapmıyor → freelist bozulması riski sürüyor. | `VDbPageHeap.pas:594-620`; `VDbPageStore.pas:2606-2665` |
| R-A-6 | Arka arkaya nesne kurulumları try'dan önce (yarım kurulum sızıntısı) | **GEÇERLİ** | Her iki örnekte de üçlü/kısıtlı `Create` bloğu `try`'dan önce duruyor; 2./3. `Create` exception'ında önceki nesneler sızar. (VDbTable satırı 5711→5855 kaydı, çalışma ağacı kirli.) | `VDbTable.pas:5855-5856`, `VDbExecutor.pas:14245-14248` |
| R-A-7 | VDbSync kilit defteri: handle kapanınca temizlenmezse sahte "kilit bende" | **GEÇERLİ (şüpheli)** | `GLockSlots` hâlâ handle-bazlı ve döngüsel; önceki raporun `CloseLockSlot` çağrısı kod tabanında ARTIK YOK (arama: 0 sonuç). Defterde `Held=True` kalan girdi, handle değeri Windows tarafından yeniden kullanıldığında sahte "kilit bende" üretir; kapanış yolları yalnız `FLockedShared/FLockedExcl` bayraklarıyla `VDbUnlockStream` çağırır ve `selfShared` yolu bu bayrakları set etmez. | `VDbSync.pas:115-159`, `137-159`, `227-320`; `VDbPageStore.pas:1917-1924`, `2063-2082` |
| R-A-8 | ReadBytesAt raise yolunda kendi aldığı paylaşımlı kilidi bırakmıyor | **GEÇERLİ** | `selfShared := True` olduktan sonraki hata `raise`'e (2072) gider; `VDbUnlockStream` yalnız döngü başarıyla biterse çağrılır (2078-2082). Bu, R-A-7 ile birleşince defterde kalıcı `Held` girdisi bırakır. | `VDbPageStore.pas:2063-2082` |
| R-A-9 | Update: geri koyma başarısızsa kayıt kaybı ("veri kaybi yok" yorumuyla çelişir) | **GEÇERLİ** | `InsertRaw` başarısız + geri koyma `InsertRaw`'ı da başarısızsa kayıt tamamen kaybolur, `Exit(False)`; yorum satırı hâlâ "veri kaybi yok" diyor. (Alan sızıntısı yok: `DeleteAt→FreeOverflow` geri veriyor.) | `VDbPageHeap.pas:1464-1478` |
| R-A-10 | VerifyFreeList / DirtyPages: satır başına `SetLength(n+1)` → O(n²) kopyalama | **GEÇERLİ** | Her iki yolda da dizi eleman başına birer birer büyütülüyor; `TxnPages` P-54 ile amortisörlü (2797+), ama bu ikisi O(n²) kaldı. | `VDbPageStore.pas:2585-2586`, `2784-2786` |
| R-A-11 | Constructor yarıda kalırsa destructor başlatılmamış CS'e DoneCriticalSection çağırır | **DÜZELTİLMİŞ** | `FWriteCsInit` bayrağı eklendi: kurulum en başta `InitCriticalSection` + flag (yorumda "R-A-11" referansıyla), yıkımda `if FWriteCsInit then DoneCriticalSection`. | `VDbPageStore.pas:187`, `660-664`, `711-712` |
| R-A-12 | Şifreli okuma/yazmada sayfa başına TBytes tahsisi (churn) | **GEÇERLİ** | `ReadPageAt`/`WritePageAt` şifreli yolunda her sayfa için `env` + `plain` TBytes tahsis edilip bırakılıyor; ortak tampon havuzu yok. | `VDbPageStore.pas:2085-2117`, `2118-2140` |
| 13 | BİLGİ: temiz işlenen yerler (VDbCrc32, ChangeLog, Executor/Tablo try..finally desenleri) | **GEÇERLİ (bilgi)** | Kapsanan yerlerde yeni ters kanıt bulunmadı; Executor hâlâ yalnız hedefli taranabildi (21.620 satır). | `VDbChangeLog.pas` (önceki rapor), genel tarama |

**Kader dağılımı:** 8 GEÇERLİ · 2 DÜZELTİLMİŞ (R-A-3, R-A-11) · 2 KISMEN (R-A-4, R-A-5) · 0 GEÇERSİZ.

### Notlar (Kısım 1)

- Düzeltmeler `d6f6f61` ("P-125") içinde commit edilmiş; çalışma ağacındaki kirli 4 dosya bu
  maddelerin kanıt satırlarını etkilemiyor (kirli dosyalar: VDbBackendV3/Executor/Sql/Table).
- R-A-4/R-A-5 için önceki raporun "DÜZELTİLDİ" hücreleri iyimser kalmış: çevrim koruması tamam,
  ama çift-FreePage ve doğrulanmamış `len` ile ön tahsis sorunları **kısmen** sürüyor.
- R-A-7 için kritik ayrıntı: önceki raporun `CloseLockSlot` (VDbPageStore.Close ~521-523) referansı
  güncel kodda bulunmuyor; defter temizliği yalnız `VDbUnlockStream` üzerinden yürüyor.

---

## KISIM 2 — Yeni bulgular (R2-A-*)

### R2-A-1 · YÜKSEK · VDbMM: SlabBits kilitsiz RMW — slab "yabancı" sanılıp FPC heap'ine FreeMem edilebilir
**Kanıt:** `VDbMM.pas:149-167`, özellikle `156-159`

```pascal
156:  slab^.Magic := SLAB_MAGIC;
158:  idx := PtrUInt(slab) shr 16;
159:  SlabBits[idx shr 3] := SlabBits[idx shr 3] or (1 shl (idx and 7));  // <- kilitsiz RMW
161:  LockAcquire;
```

- `SlabBits` bayt güncellemesi `LockAcquire`'dan **önce**, atomik olmayan oku-yaz-biçiminde yapılıyor.
- İki iş parçacığı aynı anda yeni slab ürettiğinde (FreeList + bump tükenmesi) VirtualAlloc
  **ardışık** 64KB bölgeler verir; komşu bölgeler `SlabBits`'in **aynı baytına** düşer → güncelleme
  yarışıyla bir bit kaybolur.
- Kayıp bitli slab'taki bloklar `MMFreeMem`'de `IsOurSlab=False` döner → `OldMM.FreeMem`'e
  (FPC heap) gider: VirtualAlloc bloğu FPC heap'ine iade edilir → **süreç heap'i bozulması / AV**.
- `MMSingleThreaded` yalnız test/bench araçlarında set ediliyor (`tests/bench/*.lpr`); sunucular
  (VDbPgWire/VDbSqlServer, 64 bağlantı) kilitli yolda ve VDbMM'i `VDbTable` üzerinden **her
  binary'de** kurulumda kurar (`VDbTable.pas:1084`).

**Etki:** Çok iş parçacıklı sunucuda seyrek ama yıkıcı heap bozulması. **Öneri:** SlabBits
güncellemesini `LockAcquire` bloğuna taşımak veya `InterlockedOr` ile atomik yapmak.

### R2-A-2 · ORTA · VDbMM: yeni slab yayını yarışı — BumpPtr üzerine yazma / bump alanı kaybı
**Kanıt:** `VDbMM.pas:137-167`

- Adım 2'de `LockRelease` sonrası (147) kilitsiz `VirtualAlloc` yapılır; ardından (161-167)
  `BumpPtr[sc]`/`BumpEnd[sc]` yayınlanır. İki iş parçacığı sırayla yayın yaptığında ikincisi
  birincinin slab'ının kalan bump alanını **çöpe atar** (o slab'ın boşluğu bir daha kullanılmaz).
- Sonuç veri bozulması değil, slab israfı/parçalanma; R2-A-1 ile aynı kilitsiz bölgenin yan etkisi.

**Öneri:** Slab kurulumunun tamamını kilit altında yapmak (VirtualAlloc kilitsiz kalabilir,
yayın kilitli olmalı).

### R2-A-3 · DÜŞÜK · VDbMM: MMReallocMem/MMMemSize slab başlığını doğrulamadan SizeClass okuyor
**Kanıt:** `VDbMM.pas:224-235` (`MMReallocMem`), `VDbMM.pas:245-250` (`MMMemSize`); karşılaştırma `183` (`MMFreeMem`'deki `SLAB_MAGIC` denetimi)

- `MMFreeMem` sihirli sayıyı doğrularken bu iki yol doğrulamadan `ClassSize[slab^.SizeClass]`
  okur; bozuk başlıkta `SizeClass` dizi sınırı dışında kalır (`ClassSize: array[0..15]`) →
  sınır dışı okuma, dev `Move` (231) veya yanlış boyut raporu.

**Öneri:** Aynı `slab^.Magic <> SLAB_MAGIC` korumasını bu iki yola da eklemek.

### R2-A-4 · BİLGİ · VDbMM: slab'lar asla OS'e geri verilmez + çift FreeMem sessizce bozulma üretir
**Kanıt:** `VDbMM.pas` geneli (`VirtualFree` hiç yok: 306 satırda 0 sonuç); `170-192` (`MMFreeMem`)

- Serbest bloklar free list'e gider, slab hiç `VirtualFree` edilmez → süreç belleği yüksek su
  işaretinde kalır (tasarım sonucu, sızıntı değil).
- Çift `FreeMem` aynı düğümü free list'e iki kez koyar → iki ardışık tahsis **aynı işaretçiyi**
  döndürebilir (FPC heaptrc bu tür hataları yakalardı; özel MM sessizleştiriyor).

### R2-A-5 · ORTA · VDbPool: `ActiveConnections` sayacı kaçak azalır (OpenEngine hata yolu / Release(nil))
**Kanıt:** `VDbPool.pas:375-383` (Acquire), `293-302` (ReleaseSlot), `403-427` (Release)

```pascal
376:    OpenEngine;
377:    if FShm <> nil then
378:      InterlockedIncrement(PPoolHeader(FShm.Header)^.ActiveConnections);
379:  except
381:    ReleaseSlot;        // <- ReleaseSlot koşulsuz InterlockedDecrement yapar (298)
```

- `OpenEngine` exception'ında increment **olmadan** `ReleaseSlot` decrement eder → paylaşılan
  sayaç negatife kayar. `Release(nil)` akışı (409-426, "kasıtlı" senaryo) da increment'siz
  decrement yapar. `SharedActiveCount` gözlemi bozulur.

**Öneri:** Decrement'i `ReleaseSlot`'an çıkarıp increment ile eşleşen noktaya taşımak.

### R2-A-6 · DÜŞÜK · VDbPool: yarım kurulumda destructor nil nesne üzerinde; CreateXProc'ta `inherited Create` yok
**Kanıt:** `VDbPool.pas:132-165` (Create), `304-323` (CreateXProc), `325-353` (Destroy), `409-426` (Release)

- `CreateXProc` `inherited Create` çağırmıyor; kurulum sırası (`FLock` 310 → `FAll` 313) try ile
  korumasız. `FLock := TCriticalSection.Create` exception'ında FPC destructor'ı çağırır ve
  `Destroy` `FLock.Enter` (329) ile **nil üzerinde AV**. Aynı desen `Create` için de geçerli (147).
- `Release` içinde `Sql.Free` exception fırlatırsa `CloseEngine`/`FMutex.Leave`/`ReleaseSlot`
  (424-426) atlanır → XProc modunda mutex + SHM slotu takılır (R-A-7 ile aynı sınıf risk).

**Öneri:** Destroy'da nil denetimli giriş (`if FLock <> nil then ...`); Release'i try/finally ile sarmak.

### R2-A-7 · BİLGİ · VDbPool: FIdle/FAll artık işlevsiz — kurulumda FSize TVSql üretilip hiç kullanılmıyor
**Kanıt:** `VDbPool.pas:150-156` (FIdle doldurma), `390` (Acquire her zaman yenisini kurar), `332-335` (yalnız FIdle serbest bırakılır; `FAll.Free` içeriği serbest bırakmaz)

- Sızıntı yok (kapanışta temizleniyor) ama "havuz" her `Acquire`'da yeni `TVSql` kurup `Release`'te
  serbest bırakıyor; ön kurulum ölü kod/israf.

### R2-A-8 · ORTA · VDbCdc: `FSeen` haritası sınırsız büyür (yalnız DEL ile düşer)
**Kanıt:** `VDbCdc.pas:309-324` (ekleme), `345` (yalnız silmede Remove), `83` (yorum: "yalnızca CDC parçası erişir")

- Her PUT, tam satır kopyası (`info.Vals := Copy(...)`) ile `FSeen`'e girer; silinmeyen iş
  yükünde (append-only tablolar) harita doğrusal/sınırsız büyür. `FMaxPending` (171) yalnız
  `FBuffer`'ı korur; `FSeen` için hiçbir üst sınır/eleme yok.
- Etki: uzun ömürlü CDC sürecinde bellek tükenmesi. **Öneri:** `FSeen` için de `FMaxPending`
  benzeri üst sınır ya da checkpoint'te budama.

### R2-A-9 · DÜŞÜK · VDbCdc: tampon taşma yolu O(n²) — `FBuffer.Delete(0)`
**Kanıt:** `VDbCdc.pas:357-362`

- `TList<TCDCEvent>.Delete(0)` her düşüşte tüm listeyi kaydırır; `FMaxPending` üstü her fazlalık
  için O(n) → burst'te O(k·n) kopyalama. Düşenler sayılır (361) ama kopyalama maliyeti kalır.

### R2-A-10 · BİLGİ · VDbCdc: checkpoint indeksi geri sarınca tüm WAL yeniden yayınlanır
**Kanıt:** `VDbCdc.pas:258-260`

- `FNextIndex > cnt` → `FNextIndex := 0`: geçmiş baştan işlenir; `FSeen` AddOrSetValue ile
  tazelenir ama eski olaylar tüketiciden **yeniden** yayınlanır (insert/update karışımı).
  Kaynak sızıntısı yok; olay tekrarı/semantik riski.

### R2-A-11 · ORTA · VDbPgWire: portal sonuç belleği Sync'te temizlenmiyor — bağlantı başına sınırsız birikim
**Kanıt:** `VDbPgWire.pas:1591-1603` (`ExecutePortal` tam `TSqlResult`'ı `P.Res`'e yazar),
`1774`, `1809`, `1857` (`Portals.AddOrSetValue`), `1873-1882` (yalnız 'C' Close düşürür),
`1884-1887` (Sync yalnız `skipUntilSync` + Ready gönderir)

- PostgreSQL semantiğinde `Sync` tüm portal ve işlemleri yok eder; burada portal sözlüğü
  `Res` (tüm sonuç kümesi bellekte) ile birlikte yalnızca `Close` ile düşer. İstemci adlandırılmış
  portal açıp kapatmazsa (bazı ORM/akış kalıpları) bağlantı başına bellek doğrusal büyür.
- `TPgPortal` `AddOrSetValue` ile değer tipi olarak kopyalanır; string/dizi referans sayaçlı
  olduğundan kopya sızıntısı yok — sorun birikimin **sınırısız** olması.

**Öneri:** `Sync` işleyicisinde `Portals.Clear` (spesifikasyon uyumlu) veya portal başına sonuç
üstü sınır.

### R2-A-12 · ORTA · VDbPgWire: COPY FROM STDIN geçici dosya adı yarışı (TOCTOU) — çapraz bağlantı dosya bozulması
**Kanıt:** `VDbPgWire.pas:1178-1188` (`PgTempCopyPath`), `1232-1236`, `1301-1303`

```pascal
1184:  Result := ... + 'vdb_pgcopy_' + IntToStr(GetTickCount64) + '_' + IntToStr(i) + '.tmp';
1187:  until not FileExists(Result);        // <- TOCTOU
...
1236:  fs := TFileStream.Create(path, fmCreate);   // yarışan ikinci bağlantı: truncation / EFOpenError
...
1302:  if FileExists(path) then DeleteFile(path);  // dış finally: BAŞKA bağlantının dosyasını silebilir
```

- İki bağlantı aynı ms'de aynı adı üretirse (yerel `i` her çağrıda 0'dan başlar) `fmCreate`
  ikincinin dosyayı bozması veya `EFOpenError` fırlatması mümkün; bu exception iç `try..except`
  ile **yakalanmaz** (1236, `try..finally` içinde) ve dış `finally` (1302) yarışın kazananının
  aktif kopya dosyasını silebilir → COPY veri kaybı/bozulması.
- `VDbSync.pas:57-61`'deki `VDbProcessToken` çözümü burada kullanılmamış; thread-unique artırıcı
  da yok. **Öneri:** adı süreç tokenı + interlocked sayaçla tekilleştirmek.

### R2-A-13 · DÜŞÜK · VDbPgWire: satır/mesaj üretimi O(n²) string birleştirme
**Kanıt:** `VDbPgWire.pas:503-527` (`DataRowMsgFmt`: `body := body + ...` hücre başına),
`410-425` (`RowDescMsgFmt`), `204-224` (`NetI64`/`NetF64` döngüde birleştirme)

- Hücre/sütun başına birleştirme kuadratik kopyalama yapar; geniş satırlarda (ör. 50×1KB)
  satır başına ~MB'larca gereksiz kopya. `TStringBuilder`/önceden boyutlandırma yok.
  Aynı desen `HandlePgCopyOut` satır birleştirmesinde de var.

### R2-A-14 · DÜŞÜK · VDbExecutor: BuildAsOfRows `AppendRow` satır başına `SetLength(n+1)` → O(n²)
**Kanıt:** `VDbExecutor.pas:11167-11179` (`AppendRow`: `SetLength(Pks, outn+1)`, `SetLength(Rows, outn+1)`)

- AS OF ile büyük sonuç kümelerinde (100k+ satır) dizi her satırda yeniden tahsis+kopyalanır;
  yönetilen tip olduğu için refcount trafiği de eklenir. R-A-10 ailesinin yeni yeri.

### R2-A-15 · DÜŞÜK · VDbTimeTravel: `GetValueAt` her çağrıda WAL'ı baştan tarar → toplu kullanımda O(n²)
**Kanıt:** `VDbTimeTravel.pas:148-163` (`for i := 0 to cnt - 1`), `HistoryCount` 130-137

- Tek çağrı O(WAL); satır başına çağıran bir kullanıcı döngüsü O(satır×WAL) kuadratik I/O yapar.
  Motor içi AS OF yolu (`BuildAsOfRows`) bunu kullanmıyor (kamu API riski).

### R2-A-16 · DÜŞÜK · VDbSqlServer: kilitsiz `FConns.Count` kapasite denetimi + üretim kodunda ölü mutasyon testi
**Kanıt:** `VDbSqlServer.pas:351` (`FServer.FConns.Count` — kilitsiz okuma; liste `AddConn`'da 500-522'de kilitli değişir),
`507-519` (temizlik `FConnsLock` altında `WaitFor`+`FSql.Free`), `274` (`if False and (sqlP = '')` — "mutasyon: etki testi")

- Kapasite denetimi en iyi çaba (yarışlı); `AddConn` temizliği kilit altında `FSql.Free` ile motor
  kilidine girebilir (kilit tutma süresi). Satır 274 üretim kodunda bırakılmış mutasyon-test kalıntısı.
- Ayrıca `Start` içinde varsayılan kimlik bilgileri gömülü (`admin`/`admin123`, 439-440) — kaynak
  ekseni dışı ama not edilir.

### R2-A-17 · DÜŞÜK (şüpheli) · VDbDataSet: doğrulanmamış `PAnsiChar` okuması + DoInsert kısmi başarısızlıkta yerel uyumsuzluk
**Kanıt:** `VDbDataSet.pas:190-191` (`VDbNativeToStr` else dalı: `string(PAnsiChar(Buffer))` —
null-termination garantisi olmayan tampondan okuma), `903-927` (`DoInsert`: `INSERT` sonrası
`SELECT MAX(pk)` exception'ında `FRows` güncellenmez → yerel kopya DB ile uyumsuz kalır)

- İkisi de veri sızıntısı değil; taşma okuma (savunmasız yol) ve tutarlılık riski. `Field.DataSize`
  ile kırpma yalnız `StrLCopy` yapılan dallarda var.

---

## Ek: hedefli tarama notları (bulgu değil)

- **VDbPgIo/TVdbPgConn yaşam döngüsü sağlam:** `FIO` destructor + `Execute` finally (1898-1902)
  ikilisi çift serbest bırakmayı `FreeAndNil` + nil denetimiyle önlüyor; TLS oturumu `FTls.Free`
  ile düşüyor (240-253).
- **VDbSqlServer.Stop / VDbPgServer.Stop** önce kabul thread'ini `WaitFor` ile durduruyor (345-366 /
  2064-2068), sonra bağlantıları; `AddConn` temizliği ile `Stop` snap/free yarışı bu sıra sayesinde
  kapalı.
- **HandlePgCopyIn** `Exit` yolları `try..finally` içinde; `fs` ve geçici dosya temizliği hatada da
  çalışıyor (1271-1273, 1301-1303) — ad yarışı (R2-A-12) hariç tutum doğru.
- **VDbPool.Acquire** hata yollarında mutex/slot geri veriyor (379-383, 395-400); yalnız
  sayıcı eşleşmesi bozuk (R2-A-5).

## Kapsam ve Sınırlılıklar

- Derleme/çalıştırma yapılmadı; tüm bulgular statik okuma kanıtına dayanır. `şüpheli` işaretliler
  (R-A-7 sürekli, R2-A-17) çalışma zamanı senaryosuna bağlıdır.
- `VDbExecutor.pas` (21.620 satır) yalnız hedefli örüntü taramasıyla incelendi; R-A-6 dışı
  Create/Free çiftleri doğrulanmış değildir.
- VDbMM bulguları i386-win32/Windows sanal adres modeli varsayımıyla yazıldı (SlabBits indeksleme
  `shr 16`, 64KB slab). Başka platformlarda etki farklı olabilir.
---

# EK-B — alt ajan tam raporu

# R2-B — Eşzamanlılık Doğrulama ve Yeni Bulgu Raporu (VDbMotor)

**Künye**
- Dal: `v3` — HEAD `1fe0acfb87006ca70f309f49bf341b54104f3c9e`
- **Çalışma ağacı KİRLİ**: 7 dosyada commit edilmemiş değişiklik var — `VDbBackendV3.pas`, `VDbExecutor.pas`, `VDbPageEngine.pas`, `VDbPageHeap.pas`, `VDbPageStore.pas`, `VDbPageWal.pas`, `VDbTable.pas`. Tüm satır numaraları bu kirli çalışma ağacına aittir.
- Hedef: FPC 3.2.4 / Delphi, `i386-win32` (kilit kodları Windows `LockFile/UnlockFile` yolu; `_WIN32` tanımları `i386-win32`'de doğal olarak vardır).
- Yöntem: **salt okunur statik kod incelemesi**. Derleme, çalıştırma, test veya herhangi bir dosya değişikliği yapılmamıştır (bu rapor dosyası hariç).
- Doğrulanan önceki rapor: `tmp64\r_B.md` (B-01…B-20 eşzamanlılık bulguları).
- Tarih: 6 Nisan 2026.

**Okuma notları**
- Şiddet dereceleri: **KRİTİK > YÜKSEK > ORTA > DÜŞÜK > BİLGİ**.
- Sonuç etiketleri: **GEÇERLİ** (güncel satır numaralarıyla doğrulandı), **DÜZELTİLMİŞ** (eski iddia artık güncel koda uymuyor; nerede düzeltildiği yazılı), **KISMEN** (mekanizma doğru ama etki/senaryo açıklaması hatalı), **GEÇERSİZ** (kod böyle değil).
- `(şüpheli)` işaretleri önceki rapordan aynen korunmuştur (B-15, B-16, B-17).
- Kaynak koddaki yorumlarda geçen "B-3/B-4/B-8/B-11" etiketleri **başka raporların performans numaralarıdır**; bu rapordaki B-xx etiketleri `r_B.md`'ye aittir. Karıştırılmamalıdır.

---

## KISIM 1 — Özet Tablo: Eski 20 İddianın Kaderi

| ID | İddia (kısa) | Sonuç | Şiddet | Kanıt (güncel çalışma ağacı) |
|----|--------------|-------|-------|------------------------------|
| B-01 | Tarama callback'lerinin tarama durumunu ezmesi / iç içe taramada UAF | **GEÇERLİ** | **KRİTİK** | `VDbBackendV3.pas:2565-2568, 2574, 2579-2591, 2035`; `VDbExecutor.pas:13049-13177` |
| B-02 | `TryGetIdxSource/TryGetMemIndex` kilit korumasız ortak alan yazımı | **GEÇERLİ** | **KRİTİK** | `VDbTable.pas:9657-9813`; paylaşımlı FTb: `VDbSqlServer.pas:47-54, 86-88, 169, 415-416` |
| B-03 | `AbortBatch`'in koşulsuz `EndDeferRefresh` çağrısı | **GEÇERLİ** (etki düzeltildi) | ORTA | `VDbBackendV3.pas:3104, 2874, 2917`; `VDbPageStore.pas:1660` |
| B-04 | `BeginBatch` istisna yolunda hold/defer sızıntısı | **GEÇERLİ** | **YÜKSEK** | `VDbBackendV3.pas:2880-2883, 2865, 2874` |
| B-05 | Aynı süreçte ikinci oturuma `Exit(True)` ile yazma kilidi atlatma | **GEÇERLİ** | **YÜKSEK** | `VDbPageStore.pas:1606-1644` (özellikle `1613-1617`) |
| B-06 | `VerifyNoConflict` FAlien denetiminin çakışmayı kaçırması | **KISMEN** (senaryo ters) | **YÜKSEK** | `VDbBackendV3.pas:1809-1862, 1786-1807, 2956-2970` |
| B-07 | `ReadBytesAt` hata yolunda selfShared SH sızıntısı | **GEÇERLİ** | **YÜKSEK** | `VDbPageStore.pas:2038-2083` (`2066-2072` vs `2078-2082`) |
| B-08 | Kilit defterinin "Held" sahtekârlığı / yanlış slot unlock | **GEÇERLİ** | **YÜKSEK** | `VDbSync.pas:137-159, 241-260, 291-320` |
| B-09 | `LockBookInit` DCL yarışı | **GEÇERLİ** | ORTA | `VDbSync.pas:130-135` |
| B-10 | Yükseltmede SH→EX penceresi | **KISMEN** (büyük ölçüde hafifletilmiş) | DÜŞÜK | `VDbSync.pas:246-253`; `VDbPageStore.pas:1307-1312, 1345-1349, 1676-1695` |
| B-11 | `ReleaseWrite/ReleaseDataWrite` sessiz başarısızlığı | **GEÇERLİ** | ORTA | `VDbPageStore.pas:1483-1528, 1703-1733` |
| B-12 | Busy-wait döngüleri (FWriteCs altında) | **GEÇERLİ** | ORTA | `VDbPageStore.pas:927-942, 946-965, 968-990` |
| B-13 | Store-bazlı kilit/kalıcılık sayaçlarının oturum-izolasyonu sağlamaması | **GEÇERLİ** | ORTA | `VDbPageStore.pas:167-173, 1407-1439` |
| B-14 | `FT.Backend.AbortBatch` yan etkileri (CONCURRENTLY iptali vb.) | **DÜZELTİLMİŞ** | ORTA (kalan etki) | `VDbExecutor.pas` artık `FT.*Batch` çağırıyor; kalan etki `VDbTable.pas:6421-6447` |
| B-15 | sid=0 oturum izolasyonu (şüpheli) | **GEÇERLİ** (şüpheli) | ORTA | `VDbBackendV3.pas:2847/2850, 1488-1508`; `VDbSql.pas:242-243` |
| B-16 | Kilitsiz önbellek/flag alanları (şüpheli) | **GEÇERLİ** (şüpheli) — yüzey **genişledi** | ORTA | `VDbTable.pas:7114-7118, 7140-7141, 7795-7810` |
| B-17 | `MarkDirty` / `FTOpen` ile ilgili yarış (şüpheli) | **GEÇERLİ** (şüpheli) | ORTA | `VDbTable.pas:5208-5232`; `VDbPageStore.pas:183, 327` |
| B-18 | `AwaitDurable` `FSyncBusy` bayrağının sızması | **DÜZELTİLMİŞ** | BİLGİ | `VDbPageEngine.pas:938-963` (iç try/finally `955, 958-959`) |
| B-19 | Süreç-içi kilit defterinin Windows'ta olmaması | **GEÇERLİ** | BİLGİ | `VDbSync.pas:161-180, 279-288` |
| B-20 | `CheckRowWritable` TOCTOU | **GEÇERLİ** | ORTA | `VDbTable.pas:1221-1232` |

**Sayım:** GEÇERLİ 16 · DÜZELTİLMİŞ 2 (B-14, B-18) · KISMEN 2 (B-06, B-10) · GEÇERSİZ 0.
Eski raporun hiçbir ana iddiası çürütülmedi; B-03, B-06 ve B-10'da **etki/senaryo** düzeltildi.

## KISIM 2 — Özet Tablo: Yeni Bulgular

| ID | Bulgu (kısa) | Şiddet | Kanıt |
|----|--------------|-------|-------|
| R2-B-1 | VDbMM özel bellek yöneticisinde `SlabBits` kilitsiz RMW → yanlış `OldMM.FreeMem` → heap bozulması | **KRİTİK** | `VDbMM.pas:147-167, 98-104, 177-180` |
| R2-B-2 | `FBatchSet/FBatchSetSid` iki-kelime önbelleğinin kilitsiz okunması → oturumlar arası yazma seti karışması | **YÜKSEK** | `VDbBackendV3.pas:2878-2879, 1495-1496, 1546` |
| R2-B-3 | Paylaşımlı TVTableDb üzerinde işlem durumu çakışması (snapshot, ertelenmiş FK, CONCURRENTLY iptali) | **YÜKSEK** | `VDbTable.pas:6395-6447`; `VDbExecutor.pas:19105-19110` |
| R2-B-4 | `FLastDirtyIdx` tek-girdi önbelleğinin eşzamanlı indeks düşürmeyle yanıltılması | ORTA | `VDbTable.pas:348-349, 7860-7866, 8002, 9601-9613, 9426` |
| R2-B-5 | VDbPool: `Release` sahiplik denetimsiz, instance-bazlı `FMutex`, `CloseEngine` çapraz-thread yıkım | ORTA | `VDbPool.pas:355-425`; `VDbXPrims.pas:34-61, 263` |
| R2-B-6 | VDbPool tek-süreç modunda `FSize` sınırını uygulamıyor (sınırsız TVSql üretimi) | DÜŞÜK | `VDbPool.pas:150-156, 355-401` |
| R2-B-7 | `raise Exception(pendExc)` kontrolsüz dönüşüm — ikinci hata riski | DÜŞÜK | `VDbBackendV3.pas:3070-3071` |
| R2-B-8 | `SetDurableLsn` süreçler-arası monotonlik ihlali (etki: benign) | BİLGİ | `VDbPageStore.pas:1259-1269` |
| R2-B-9 | TVdbGate `Leave`'in sırasız yığın kullanımı | DÜŞÜK | `VDbBackendV3.pas:1002-1087` |

---

## KISIM 1 — Detaylar (satır satır izleme)

### B-01 (KRİTİK, GEÇERLİ) — Tarama callback zinciri: tarama durumu ezilmesi + iç içe taramada use-after-free

**Mekanizma (güncel satırlarla):**
1. `TVdbBackendV3.StreamCbRaw` (`VDbBackendV3.pas:2536`) tek giriş noktasıdır; paged varyant aynı kalıptır (`2645-2648`).
2. `2565-2568`: `FStreamCb`, `FStreamUser`, `FStreamAbort`, `FStreamFilter` alanları **`FEngCs.Enter` ÖNCESİ** yazılır. Kritik bölüm yalnız tarama döngüsünü korur; alanların kendisi korumasızdır.
3. `2574` (SnapBuild) `FSnapMap`'i kurar; `2579-2591` döngüsü `for pair in FSnapMap` ile haritayı gezerken `2588` (RowCb) ve `2590` (EndCb) **kullanıcı callback'leri** çağrılır.
4. Kullanıcı callback'i bir alt sorgu başlatırsa yeni bir tarama açılır ve `TVdbBackendV3.ScanRows` (`2035`) `FreeAndNil(FSnapMap)` yapar. Dış döngü (`2579`) serbest bırakılmış haritayı gezmeyi sürdürür → **use-after-free**.
5. `TVdbGate` (`1002-1087`) threadvar tabanlı kapı sayacı **yeniden girişi serbest bırakır** (aynı thread), dolayısıyla bu senaryoyu engellemez. Kapı yalnızca "tarama ortak alanına dokunma" sözleşmesine dayanır; callback'in alt sorgu çalıştırması bu sözleşmeyi bozar.

**Callback zinciri (kanıt):** `VdbStreamSelCb` (`VDbExecutor.pas:13049`) → satır başına `RowMatches` (`13138-13139`) → `EvalExpr` (`13170/13177`) → `SubResult` (`2943`) → `ExecSelect` (`2967`) → alt sorgu `EvalExpr` (`2092/2149/2203`) → `ScanRawIterAll` ile yeni tarama → `FSnapMap` serbest bırakma (`2035`).
Tarama yüzeyi: `5506, 9127, 10381, 11016, 13341, 13921-13934, 14061, 14164`.

**Etki:** bellek bozulması (UAF), yanlış sonuç satırları, yanlış `FStreamAbort` işaretçisi. Kritik bölümde değil, kilitsiz alan yazımı nedeniyle eşzamanlı iki tarama da birbirinin callback'ini ezerek yanlış callback ile satır üretebilir.

### B-02 (KRİTİK, GEÇERLİ) — `TryGetIdxSource`/`TryGetMemIndex`: kilit korumasız paylaşımlı indeks durumu

**Mekanizma:**
- `TVTableDb.TryGetIdxSource` (`VDbTable.pas:9657-9729`): `9680` `FlushIdxPending` (kirli indeksleri inşa eder), `9684/9693` `SetIdxSkipFromEntries`, `9691` `BuildOneIndex` — **hiçbirinde kilit yok**; yalnız `IsBuilding` filtresi (`9663`) vardır.
- `TVTableDb.TryGetMemIndex` (`9731-9813`): `9763` `FlushIdxPending`; `9777` `FMemIdx.AddOrSetValue`; `9785` `BuildOneIndex`; `9804-9806` `FPkIdx`/`BuildPkIdx`; `9808` `FHasIdxWorkTid := 0`.
- **FTb (TVTableDb) tüm bağlantılar arasında paylaşıldığı** yorumlarla da sabittir: `VDbSqlServer.pas:47-48` ("ayni Ftb paylasilir"), `54`, `86-88`, `169` (`FSql := TVSql.Create(AServer.Ftb)`), `415-416`; `VDbPgWire.pas:49, 115, 1507`; `VDbPool.pas:52, 154, 390`. Her bağlantı kendi `TVSql`/`TVSqlExecutor`'ına sahip ama ortak `TVTableDb`'ye yazar.
- Paralel okuyucular: `VDbSql.pas:3184/3315/3416` (`LockRead` altında planlama yapar; bu önbellekler backend kilitleriyle korunmaz).

**Etki:** eşzamanlı iki sorgu aynı tablo için indeks planlarken `FMemIdx` (dynamic array/string içeren sözlük) üzerinde yazma-yazma veya yazma-okuma yarışı → dynamic array refcount bozulması (UAF), çift indeks inşası, `FHasIdxWorkTid` sahte temizliği yüzünden bayat indeksle yanlış sonuç. Süreç-çapında, çok bağlantılı sunucuda tetiklenir.

### B-03 (ORTA, GEÇERLİ — etki düzeltildi) — `AbortBatch`'in koşulsuz `EndDeferRefresh` çağrısı

**Güncel mekanizma:**
- `BeginBatch` (`VDbBackendV3.pas:2847-2883`): `2865` `AcquireSet` yalnız `gotReserve` ise (yazma hold'u) `BeginDeferRefresh` çağırır (`2874`). `gotReserve=False` (optimistic) yolda FDeferCount artırılmaz.
- `CommitBatch` (`2896-2932`): `2917` `EndDeferRefresh`; sonra `VerifyNoConflict` (`2948`) veya `ApplyBatch` hatasında `AbortBatch` çağrılır.
- `AbortBatch` (`3087-3124`): `3104` **koşulsuz** `EndDeferRefresh` çağırır.

**Düzeltme (eski etki yanlış):** `EndDeferRefresh` `FDeferCount` 0 iken kıstığı için (`VDbPageStore.pas:1660`) sayaç negatife gitmez; eski rapordaki "sayaç negatif olur → FDeferCount ≠ FRefreshWriters" etkisi doğrudan oluşmaz. Ayrıca `pendExc` yolu (`FSets.Remove` `2991`) `3087`'de erken çıktığı için o yolda çift düşüş yoktur.

**Gerçek kalan etki:** `FDeferCount` **store genelidir** (oturum-bazlı değil). `AbortBatch` kendi setini düşürdükten sonra yaptığı `EndDeferRefresh` (`3104`) başka bir oturumun `FDeferCount`'unu 1 azaltır; o oturumun yazma kilidi beklenenden önce çözülür (`NeedBefore` kapısı erken açılır) → optimistik doğrulama penceresi genişler. Yine de istisnai bir yol olduğu için ORTA.

### B-04 (YÜKSEK, GEÇERLİ) — `BeginBatch` istisna yolu: hold/defer sızıntısı

`2880-2883` istisna yakalama bloğu yalnız `gotReserve` ise hold bırakır; `gotReserve=False` yolunda (`AcquireSet` `2865` + `BeginDeferRefresh` `2874` sonrası bir istisnada) `FDeferCount` artmış kalır ve tahsis edilen `TWriteSet` (`2865`) havuza geri dönmez. `FBatchSet/FBatchSetSid` (`2878-2879`) zaten yazılmıştır; `FBatchOpen` hâlâ `True`'dur (`2879`). Sonuç: kalıcı defer sızıntısı (sonraki oturumların yazma kilidi NeedBefore'sız çözülür) + set havuzu sızıntısı.

### B-05 (YÜKSEK, GEÇERLİ) — Aynı süreçte ikinci oturuma yazma kilidi atlatma

`TVPageStore.TryAcquireWriteHold` (`VDbPageStore.pas:1606-1644`): `1613-1617` — `FHoldDepth > 0` iken aynı süreçten gelen ikinci oturum `Exit(True)` döner ve `NeedBefore=False` fast-path'i kullanır. `FHoldDepth` **store genelidir** (`167-173`); oturum sahipliği tutulmaz. Böylece iki "oturum" aynı anda yazma yetkisiyle çalışır; birincinin `VerifyNoConflict`'i ikincinin yazımlarını `S.Before`'a almadığı için çakışma tespiti B-06'nın boşluğuna düşer.

### B-06 (YÜKSEK, KISMEN) — `VerifyNoConflict` FAlien denetimi

`TVdbBackendV3.VerifyNoConflict` (`1809-1862`):
- `1831`: FAlien denetimi yalnızca **S.Before'da OLMAYAN** anahtarlar için yapılır.
- `1845-1860`: Before değerleri ile canlı değerler karşılaştırılır.
- FAlien yalnız `FSets.Count > 1` ise doldurulur (`2956-2970`) ve `2995`'te temizlenir.

**Düzeltme (eski senaryo ters):** önceki rapor "yabancı commit NoteBefore'dan SONRA yazılsa da FAlien yakalar" diyordu; asıl kaçan pencere bunun tersidir — yabancı commit **okuma ile `NoteBefore` (`1786-1807`, write-anı before-image) arasına** düşerse, kendi yazımı zaten `S.Before`'a (o ana dek okunan değer) yansır; karşılaştırma eşit görür ve çakışma kaybolur ("ilk commit kazanır" ilkesi ihlal edilir). NoteBefore sonrasındaki yazımlar ise değer karşılaştırmasıyla yakalanır. Bu hâlâ YÜKSEK: pencere write-anı ile before-image arasında çok dardır ama B-05'in ikinci-oturum atlatmasıyla birleşince kasıtlı olarak genişletilebilir.

### B-07 (YÜKSEK, GEÇERLİ) — `ReadBytesAt` hata yolunda selfShared SH sızıntısı

`TVPageStore.ReadBytesAt` (`VDbPageStore.pas:2038-2083`):
- `2066-2068`: `selfShared` — `FHoldDepth > 0` iken kendi kendine SH alınır.
- `2072`: hata durumunda `raise` edilir; **SH bırakılmaz**. Temizlik yalnız başarı yolundadır (`2078-2082`).
- Sızan SH, sonraki `AcquireWrite` yükseltmesini (B-10) ve EX kilidini **ölümcül kilit** (deadlock) hâline getirir; kilit kitabında da sahte "Shared" kaydı kalır (B-08/B-19).

### B-08 (YÜKSEK, GEÇERLİ) — Kilit defteri "Held" sahtekârlığı / yanlış slot unlock

`VDbSync.pas`:
- `LockSlotOf` (`137-159`): kilit slotu **handle indeksine** göre seçilir (`145`).
- `241-260`: kitap "Held" diyorsa **OS'e hiç dokunmadan** `True` döner.
- `291-320`: unlock slot tabanlıdır; tutulmayan slotu çözemez.

İkinci oturum, birinci oturumun tuttuğu slotu unlock edemez; Windows `UnlockFile` kuralı (kilidi açan süreç değil **thread** yetkilidir; sahibi thread dışında `fclose` kilit bırakmaz) nedeniyle kilit kalıcı kalır veya yanlışlıkla çözülür. Süreç-içi defterin sahte "Held" durumu bu yanlışlığı gizler (B-19).

### B-09 (ORTA, GEÇERLİ) — `LockBookInit` DCL yarışı

`VDbSync.pas:130-135`: çift kontrol kilitleme (DCL) kalıbı, kitap başlatma bayrağını kilitsiz okur/yazar. İki thread eşzamanlı ilk kilidi aldığında kitap iki kez kurulabilir veya yarım kurulmuş hâlde görülebilir.

### B-10 (DÜŞÜK, KISMEN) — SH→EX yükseltme penceresi

`VDbSync.pas:246-253`'te yükseltme sırasında SH önce bırakılır (aralık penceresi). Ancak `AcquireWrite`/`AcquireDataWrite` bunu **bilerek** yapar (`VDbPageStore.pas:1307-1312, 1676-1681` — "veri yolu önce yaz kilidine geçer") ve hata yollarında `FReadDepth > 0` ise SH'yi yeniden alır (`1345-1349, 1691-1695`). Bu nedenle derece DÜŞÜK'e iner; kalan risk, pencerenin B-07'nin sızan SH'siyle birleşmesidir (ölümcül kilide dönüşür).

### B-11 (ORTA, GEÇERLİ) — `ReleaseWrite`/`ReleaseDataWrite` sessiz başarısızlığı

- `ReleaseWrite` (`1483-1528`): `FWriteCs` altında (`1488`) 5 sn retry (`1516-1522`); başarısız olursa **sessizce** `FLockedShared := False` yapar (`1523`) — hata raporlamaz.
- `ReleaseDataWrite` (`1703-1733`): aynı kalıp (`1721-1728`, sessiz düşüş `1728`).

Sonuç: çözülemeyen kilit sessizce "çözüldü" sanılır; sonraki oturum kilit beklemede takılır ve kilit defteri (B-08/B-19) durumu yanlış gösterir.

### B-12 (ORTA, GEÇERLİ) — Busy-wait döngüleri

`TakeSharedLock` (`927-942`), `LockExclusive` (`946-965`), `LockReserve` (`968-990`) — hepsi `FWriteCs` altında çağrılır (`1281/1405/1547/1611/1672`). `Sleep(0)`'lu sıkı döngüler, kilit uzun süre tutulduğunda (fsync, büyük tarama) CPU yakar ve gecikme üretir; ayrıca `FWriteCs` altında beklemek diğer tüm kilitleme girişimlerini bloke eder.

### B-13 (ORTA, GEÇERLİ) — Store-bazlı sayaçlar

`VDbPageStore.pas:167-173`: kilit derinlikleri ve sayaçlar **store genelidir**; `AcquireRead` (`1407-1439`) ve benzeri yollar oturum ayrımı yapmaz. B-05/B-03'ün kök nedeni budur: oturum sahipliği tutulmadığı için "benim tuttuğum kilit" ile "sürecin tuttuğu kilit" ayırt edilemez.

### B-14 (ORTA, DÜZELTİLMİŞ) — Artık `FT.*Batch` çağrılıyor; kalan yan etkiler

**Düzeltildi:** `VDbExecutor` artık `FT.Backend.*Batch` yerine `FT.BeginBatch/CommitBatch/AbortBatch` çağırıyor: `15669/15814/15816`, `16255/16264/16266`, `17114/17152/17155`, `18021/18074/18079`, `18265/18280/18285` (eski rapordaki 4 siteye ek olarak `17114` bloğu da var). `FT.BeginBatch` (`VDbTable.pas:6395-6404`) sema yedeği alır (`SnapshotSchema`), `FKvB.BeginBatch` çağırır.

**Kalan etki (ORTA):** `FT.AbortBatch` (`VDbTable.pas:6421-6447`) hâlâ:
- `6434` `StopConcBuilders` — `FConcBuilders` **FT üzerinde (paylaşımlı)** olduğu için başka bağlantıların süren `CREATE INDEX CONCURRENTLY` inşalarını iptal eder (yorum `6430-6433` bunu "tek güvenli seçenek" olarak kabul eder),
- `6441` `FDeferredRows.Clear` — paylaşımlı ertelenmiş FK denetim listesini siler (bkz. R2-B-3),
- `6442` `RestoreSchemaSnapshot` — paylaşımlı sema yedeğini geri yükler,
- `6443-6446` **tüm** indeksleri veriden yeniden kurar (büyük maliyet; eşzamanlı yazmalarla yarışır).

### B-15 (ORTA, GEÇERLİ — şüpheli) — sid=0 oturum izolasyonu

`BeginBatch` `2847/2850`, `OwnSet` `1488-1508`; `VDbBackendApi.pas:362-370`; `VDbCore.pas:853-864`; `VDbSql.pas:242-243` (`property Backend read FT.Backend` — oturum kimliği doğrudan backend'e taşınmaz). sid=0 yolları yazma setini oturuma sahiplenmez; `VDbSqlServer` her bağlantıyı `FSessionId := 1` yapar (`253, 438`) — yani gerçek oturum ayrımı yok, hepsi sid=1 gibi görünür. `(şüpheli)` etiketi korunur: izolasyon ihlalinin kesin kanıtı statik incelemeyle üretilemedi, mekanizma doğrulandı.

### B-16 (ORTA, GEÇERLİ — şüpheli) — Kilitsiz önbellek/flag alanları (yüzey genişledi)

Eski iddiaya ek olarak şu **yeni** kilitsiz önbellek yazıları da doğrulandı (hepsi paylaşımlı FTb üzerinde):
- `FPrefixCacheName/FPrefixCacheVal` — `PutRow` içinde (`VDbTable.pas:7114-7118`),
- `FOpenTDef/FOpenTDefValid` — Insert yolu (~`10489`), geçersiz kılma `ResetBatchTableCache` (`6376-6393`, özellikle `6391-6392`),
- `FHasIdxWork*` — `HasIdxWork` (`7795-7810`); `PutRow` kapısı `7140-7141`,
- Geçersiz kılma: `MarkSchema` (`5995`), `LoadSchema` (`5662`).

Doğrudan API kullanıcıları (`VDbJson.pas:2543/2634-2642`, `yonetim\hadtools.pas:210/218`) bu alanları sunucu bağlantısı olmadan da yazabilir. `(şüpheli)` etiketi korunur.

### B-17 (ORTA, GEÇERLİ — şüpheli) — `MarkDirty`/FTOpen yarışı

`VDbTable.pas:5208-5232`; `VDbPageStore.pas:183, 327`; `VDbBackendApi.pas:192-194`. Mekanizma doğrulandı; kesin etki kanıtı üretilemedi, `(şüpheli)` korunur.

### B-18 (BİLGİ, DÜZELTİLMİŞ) — `AwaitDurable` `FSyncBusy` sızıntısı

`VDbPageEngine.pas:938-963`: artık iç `try/finally` var; `955` `FSyncBusy` temizliği ve `958-959` `FSyncEvt` uyandırması her yolda çalışıyor. Eski iddia düzeltildi; geriye yalnız "nadir eşzamanlılıkta gereksiz bekleme" bilgi notu kalır.

### B-19 (BİLGİ, GEÇERLİ) — Süreç-içi kilit defteri Windows'ta yok

`VDbSync.pas:279-288`: Unix yolunda defter tutulmaz; `VDbLockHeld` (`161-180`) yalnız Windows'ta anlamlıdır. B-08/B-11'in teşhisini zorlaştırır.

### B-20 (ORTA, GEÇERLİ) — `CheckRowWritable` TOCTOU

`VDbTable.pas:1221-1232`: yazılabilirlik denetimi ile yazım arasında zaman penceresi; denetim sonuçları write kilidiyle kuşatılmadıkça (B-05/B-06 birleşimi) ihlal edilebilir.

---

## KISIM 2 — Yeni Bulgular

### R2-B-1 (KRİTİK) — VDbMM özel bellek yöneticisi: `SlabBits` kilitsiz RMW → yanlış `OldMM.FreeMem` → heap bozulması

`VDbMM.pas`, `initialization`'da `SetMemoryManager(mm)` ile **süreç geneline kurulur** (`286, 300, 303`); `VDbTable.pas:1084` `uses VDbMM` ile herhangi bir sunucu yolunda etkinleşir.

1. `MMGetMem` yeni slab yolunda (`149-167`): `LockRelease` (`147`) **sonrası**, `LockAcquire` (`161`) **öncesinde** `SlabBits[idx shr 3] := SlabBits[idx shr 3] or (1 shl (idx and 7))` (`158-159`) yapılır — bu bir **read-modify-write ve kilidin DIŞINDADIR**.
2. İki thread eşzamanlı yeni slab tahsis ettiğinde bit güncellemelerinden biri **kaybolur** (lost update).
3. `IsOurSlab` (`98-104`) `SlabBits`'i **kilitsiz** okur; kayıp bit, slab sahibi bloğun sahipsiz görünmesine neden olur.
4. `MMFreeMem` (`170-181`): `not IsOurSlab(P)` ise blok `OldMM.FreeMem(P)`'e yollar (`177-180`). Bu, ortasından işaretçi serbest bırakılan FPC varsayılan heap'idir → **heap metadata bozulması**, süreç çapında bellek yolsuzluğu (daha sonraki herhangi bir tahsis/serbest bırakma patlayabilir).

Ek sorunlar (aynı birim):
- `162`: `BumpPtr[sc] := PByte(slab) + SLAB_HDR` — kilitle korunsa da, `147-161` aralığında başka bir thread de yeni slab'a geçmişse **önceki slab'ın kalanı tamamen sızar** (üzerine yazma; zincir yok).
- `LockAcquire` (`69-74`): `while InterlockedExchange(MMLock, 1) <> 0 do ;` — `Sleep(0)`/`SwitchToThread` **yok**; yüksek eşzamanlılıkta (çok bağlantılı sunucu) CPU yakar, düşük öncelikli thread'ler aç kalabilir (priority inversion).
- `MMSingleThreaded` (`28`) **global** bir bayraktır; süreçte herhangi biri `True` yaparsa tüm thread'ler için kilitler kapanır. Yalnız bench `.lpr` dosyalarında ayarlandığı görüldü; kütüphane kodu bunu doğrulamaz.

**Neden KRİTİK:** bellek bozulması doğrudan veri bütünlüğüne ve süreç kararlılığına vurur; çok bağlantılı sunucu (aynı anda birçok tahsis) tam tetikleyici yüktür; ve VDbMM kurulduğu anda süreçteki *tüm* Pascal tahsisleri bu yoldan geçer.

**Öneri:** `158-159`'daki `SlabBits` güncellemesini `LockAcquire`'dan sonraki kritik bölüme taşı (veya `InterlockedOr` kullan); `BumpPtr` yenilemesini de tek kritik bölümde "yalnız boşsa" koşuluyla yap; `LockAcquire` döngüsüne `Sleep(0)` ekle.

### R2-B-2 (YÜKSEK) — `FBatchSet/FBatchSetSid` iki-kelime önbelleği: kilitsiz okuma → oturumlar arası yazma seti karışması

`TVdbBackendV3.BeginBatch` yazım sırası: `2878` `FBatchSet := S`, `2879` `FBatchSetSid := sid` — ikisi de `FEngCs` altındadır. Ama okuyucular kilitsizdir:
- `OwnSet` (`1488-1508`): `1495-1496` `FBatchSet`/`FBatchSetSid`'i kontrol eder,
- `GetBatchOpen` (`1546`).

Eşzamanlı başlatma/yükseltmede ikinci kelime (`FBatchSetSid`) yazılmadan önce birinci (`FBatchSet`) görünürse, başka bir oturum **kendisinin olmayan `TWriteSet`'i** "OwnSet" olarak alır. Sonuç: iki oturum aynı write-set'e yazar (`Put`/`NoteBefore` ortak `S.Before`'a akar) → `VerifyNoConflict` artık oturum ayrımı yapamaz, B-06'nın boşluğu kasıtlı kullanıma açık hâle gelir; yanlış oturumun abort'u diğerinin yazımlarını da geri alır.

**Öneri:** iki alanı tek atomik kayıtta (önce `FBatchSetSid` yaz, `FBatchSet`'i `FEngCs` altında yaz ve okumaları da `FEngCs` altında yap) veya `OwnSet`'i `FEngCs` altına al.

### R2-B-3 (YÜKSEK) — Paylaşımlı TVTableDb üzerinde işlem durumu çakışması

`Ftb` tüm bağlantılar arasında **tek** `TVTableDb`'dir (`VDbSqlServer.pas:47-54, 86-88, 169`; `VDbPgWire.pas:49`). Üzerindeki işlem durumu da tektir:
- `SnapshotSchema` (`VDbTable.pas:6126-6152`): her `BeginBatch` `6400` çağrısı **önceki sema yedeğini ezer** (`FSnapActive`, `FSchemaSnap*` tek takımdır).
- `RestoreSchemaSnapshot` (`6154-6181`) / `ClearSchemaSnapshot` (`6414`).
- `ClearSavepoints` (`6215-6229`), `FKvB` savepoint'leri (`6309-6348`).
- `FDeferredRows.Clear` (`6441`) — başka oturumun ertelenmiş FK denetimlerini siler: ertelenen satır, `COMMIT`'te (`7041`) doğrulanmadan geçebilir → **FK ihlali sessizce commit edilir**.
- `StopConcBuilders` (`6434`) — başka bağlantıların CONCURRENTLY inşalarını iptal eder (B-14).
- `FT.BeginBatch` (`6395-6404`) `RequireSoleTxn` **çağırmaz**; `RequireSoleTxn` (`6003-6014`) yalnız DDL/SAVEPOINT yollarını korur.
- `VDbExecutor.pas:19105-19110`: `txBegin` açık işlemi cümleler **arasında** tutar — dolayısıyla iki bağlantı aynı anda açık işlemle yaşar.

Senaryo: A `BEGIN`, B `BEGIN` (B'nin `SnapshotSchema`'sı A'nın yedeğini ezer); B `ROLLBACK` (`RestoreSchemaSnapshot` A'nın DDL'ini geri alır / `FDeferredRows.Clear` A'nın FK listesini siler / A'nın CONCURRENTLY inşası iptal). Kalan DDL rollback'ten sağ çıkabilir veya yanlış sema kalıcılaşır.

**Öneri:** `FT.BeginBatch`'a `RequireSoleTxn` (tek-yazar işlem) zorunluluğu getir veya snapshot/savepoint/deferred-liste durumunu oturum-bazlı (sid-keyed) tut.

### R2-B-4 (ORTA) — `FLastDirtyIdx` tek-girdi önbelleği yanıltılabilir

`VDbTable.pas:348-349` (alan), `7860-7866` (ekleme). Eşzamanlı indeks düşürme (`8002`, `9601`, `9613`) veya `ResetBatchTableCache` (`9426`) tek-girdi önbelleği geçersiz kılar; `IndexOf`/`Add`'in atlanması **kirli indeks takibinin kaybolmasına** → bayat indeksle okuma yapılmasına yol açar. B-02'nin amplifikatörüdür (paylaşımlı FTb üzerinde).

### R2-B-5 (ORTA) — VDbPool: sahiplik denetimsiz `Release`, instance-bazlı `FMutex`, çapraz-thread yıkım

`VDbPool.pas`:
- `FMySlot`/`FSlotBusy`/`FMutex` **örnek bazlıdır** (thread değil; sınıf dokümantasyonu `40-47` "thread değil bağlantı" der).
- `Release(nil)` veya başkasının `TVSql`'ini `Release` etmek `FMutex.Leave`'i (`425`) sahip olmayan thread'den çağırır; `CloseEngine` (`424`) **başka thread'in** `TVSql`'inin referansı olan `FTb`'yi serbest bırakabilir → use-after-free.
- `FMutex.Enter` (`372`) **zaman aşımısızdır**; sahipsiz kalan mutex süreçteki tüm havuz kullanıcılarını kilitler.
- `TCriticalSectionEx` Windows named mutex'tir (`VDbXPrims.pas:34-61`); `Unlock` "kilit yokken unlock çağrıldı (bug)" (`263`) yutulur ve `FLocked` örnek bazlıdır.

### R2-B-6 (DÜŞÜK) — VDbPool tek-süreç modu: `FSize` uygulanmıyor

`Acquire` (`355-401`) tek-süreç yolunda `FSize`'a bakmaz, `FAvail`'de beklemez; `FIdle`/`FAll` (`150-156`) yalnız isim olarak kullanılır. Başlık sözleşmesi (`5-27`) uygulamayla uyuşmaz: sınır yok, `TVSql.Create(FTb)` (`390`) ihtiyaç oldukça çağrılır → kaynak sınırsız büyür.

### R2-B-7 (DÜŞÜK) — `raise Exception(pendExc)` kontrolsüz dönüşüm

`VDbBackendV3.pas:3070-3071`: `pendExc` `ExceptObject`'tür; `Exception(pendExc)` dönüşümü doğrulanmaz. `Exception` olmayan bir nesne (ör. `EAccessViolation` dışı TObject atması) raise edilirse ikinci hata oluşur ve asıl hata yutulur.

### R2-B-8 (BİLGİ) — `SetDurableLsn` süreçler-arası monotonlik

`VDbPageStore.pas:1259-1269`: `FDurableLsn` kilitsiz ve süreç-içidir; çok süreçli kullanımda (SHM) monotonlik garantisi yoktur. Etki benign (dayanıklılık bekleme penceresi); bilgi olarak kayıtlıdır.

### R2-B-9 (DÜŞÜK) — TVdbGate `Leave` sırasız yığın

`VDbBackendV3.pas:1002-1087`: kapı threadvar'dır; `Leave` (`1069-1087`) çağıran hataya bağlı sıralamayla yapılır. Hata yollarında `Enter` sırasının tersinde çıkılırsa yığın (eğer tutuluyorsa) bozulur; kapı sayacı da 0'a inmezse kilit kalıcı kapanır.

---

## İncelenip sorun BULUNMAYANlar

1. **`TVdbConcIdxBuilder` işçileri** (`VDbTable.pas:8244-8276`): işçi thread'leri paylaşımlı duruma dokunmaz; sonuç aktarımı ana thread'de `PollConcurrentIndexes` (`8301-8374`) üzerinden yapılır. `FConcBuilders` listesine ekleme/çıkarma ana thread'dir (B-14'teki iptal etkisi paylaşımlı olmakla birlikte liste yarışı yok).
2. **`TryAllocateSlot`** (`VDbXPrims.pas:730-751`): SHM üzerindeki tahsis `Interlocked` ile atomiktir; süreçler arası slot yarışı yok.
3. **`AwaitDurable` ↔ `AcquireWrite` kilit sırası** (`VDbPageEngine.pas:866-970, 1106-1146`): `FSyncCs` ve `FWriteCs` arasında AB-BA sıralaması bulunamadı; `SetDurableLsn` (R2-B-8) kilitsiz olduğu için kilit hiyerarşisine girmez.
4. **VDbBackendV2 yolundaki `TVDb.BeginBatch/CommitBatch/AbortBatch`** (`VDbCore.pas:4570-4739`): v3 motoru inceleme kapsamındadır; v2 aynı iddialar için ayrıca incelenmemiştir (kapsam notu).

## Kapsam sınırları

- Derleme, çalıştırma, test **yapılmadı**; bulgular statik okumadan ibarettir. "(şüpheli)" işaretli maddeler (B-15/16/17) çalışma zamanı kanıtı gerektirir.
- `i386-win32` kilit davranışları (özellikle `UnlockFile`'ın thread-sahipliği ve `fclose`-tetikli unlock) belgelere dayanır; platforma özel doğrulama yapılmadı.
- Eski raporun B-01…B-20 dışındaki (C-, R-, P- etiketli) performans bulguları bu raporun kapsamı dışındadır.

## Kapanış — Öncelik sırası

1. **R2-B-1** (VDbMM `SlabBits`) — tek satırlık taşıma ile giderilebilir; bellek bozulması olduğu için ilk sırada.
2. **B-01** (tarama callback UAF) — `FSnapMap`'i callback sırasında kopyalayarak/zimmetleyerek veya iç içe taramayı geçici alanlarla (stack-of-scan-context) çözerek.
3. **B-02 + R2-B-2 + R2-B-4** (paylaşımlı FTb kilit korumasız durum) — `TryGetIdx*/OwnSet/FLastDirtyIdx` alanlarına `FEngCs` (veya FT-bazlı kilit) getirerek.
4. **B-05 + B-06 + B-07** (hold/VerifyNoConflict/SH sızıntısı) — oturum sahipliği (B-13) eklenerek ve `ReadBytesAt` finally'si düzeltilerek.
5. **R2-B-3 + B-14** (işlem durumu oturum-bazlı veya `RequireSoleTxn` zorunlu).
6. **B-08 + B-11 + B-19** (kilit defteri/sessiz release) — hata raporlama ekleyerek; **R2-B-5** (havuz sahipliği).
7. **R2-B-3..R2-B-9** kalan ORTA/DÜŞÜK maddeler.
---

# EK-C — alt ajan tam raporu

# VDB v3 — Eksen C Yeniden Denetim (R2): Çökme Güvenliği / Dayanıklılık / Kurtarma

- **Kod ağacı:** D:\veritabani (dal v3, HEAD `1fe0acf`)
- **DURUM: ÇALIŞMA AĞACİ KİRLİ** — 7 dosyada commit edilmemiş değişiklik var (VDbBackendV3, VDbExecutor, VDbPageEngine, VDbPageHeap, VDbPageStore, VDbPageWal, VDbTable). İnceleme bu dosyaların ÇALIŞMA AĞACI (en güncel) hâline karşı yapılmıştır.
- **Kapsam:** Eksen C (fsync sıralaması, yarım kayıt/kurtarma, checkpoint budama politikası, çökme sonrası tutarsızlık, yanlış "durabil" raporlama).
- **Yöntem:** Salt-okunur statik inceleme. Kaynak dosya değiştirilmedi, derleme/çalıştırma yapılmadı. (Yalnızca bu rapor dosyası yazılmıştır.)
- **Şiddet:** KRİTİK > YÜKSEK > ORTA > DÜŞÜK > BİLGİ. "Şüpheli": kod yolu doğrulanmış ama çalışma-anı koşullarına (eşzamanlılık, istisna zamanlaması) bağlı senaryolar.

---

## KISIM 1 — 2026-11-06 tarihli r_C.md bulgularının (C-1 … C-16) kaderi

| # | Eski şiddet | KARAR | Tek cümle |
|---|--------|--------|-----------|
| C-1 | KRİTİK | **GEÇERLİ** | Checkpoint/Truncate hâlâ veri dosyasına hiç yazılmamış onaylı sayfaları WAL'den buduyor; sayfa LSN damgası doğrulaması eklenmemiş |
| C-2 | KRİTİK | **KISMEN DÜZELTİLMİŞ** | SwapDbFileWith `.gen` durabil LSN'ini sıfırlıyor (VACUUM/RESTORE/REKEY kapandı); silinip yeniden yaratılan/kopyalanan DB'de bayat `.gen` yaşıyor |
| C-3 | KRİTİK | **GEÇERLİ** | Temiz kurulum + önbellek tahliyesi + MinLSN atlama zinciri aynen duruyor; okuma yolunda bayatlık denetimi yok |
| C-4 | YÜKSEK | **GEÇERLİ** | `Refresh` hâlâ `FWrittenLsn := FLSN` ile değeri kasıtlı düşürüyor; AwaitDurable asılı kalabilir |
| C-5 | YÜKSEK | **GEÇERLİ** | Checkpoint/Compact/Restore/Verify hâlâ süreçler arası yazma kilitsiz; yeni ek: BackupTo ve EnsureLogBase de kilit noktaları |
| C-6 | YÜKSEK | **DÜZELTİLMİŞ** | CommitBatch istisnayı yakalayıp AwaitDurable'ı garantiye alıyor ve hatayı yeniden yükseltiyor (bkz. R2-C-2 artığı) |
| C-7 | YÜKSEK | **GEÇERLİ** | StoreRefreshed korumaları hâlâ DropCache/InstallPending'den sonra; FPendingCount kontrolü hâlâ dead-code |
| C-8 | YÜKSEK (şüpheli) | **GEÇERLİ** | Artımsal tarama koruması hâlâ bellek-içi `hdrLsn := FLSN` + `FScanPos <= Size` |
| C-9 | ORTA | **GEÇERLİ** | WAL başlığı yarım yazılınca DB hâlâ hiç açılamıyor |
| C-10 | ORTA | **GEÇERLİ** | TornTail hâlâ sessizce yutuluyor; orta-şerit bozulmada sonraki tüm commit'ler sessiz atlanıyor |
| C-11 | ORTA (şüpheli) | **GEÇERLİ** | AS OF taban+WAL kopyası hâlâ kilitsiz; ek: `CommitCount` kilit dışı `Recover` yan etkisi (R2-C-4) |
| C-12 | ORTA | **GEÇERLİ** | Değişim günlüğü fsync'i hâlâ WAL fsync'inden önce; yalnızca yanlış yorum düzeltildi |
| C-13 | DÜŞÜK | **DÜZELTİLMİŞ** | `WAL.Bytes` şifreli modda çerçeveyi doğru boyutlandırıyor |
| C-14 | DÜŞÜK | **DÜZELTİLMİŞ** | fsync istisnasında tampon temizleniyor (artık yinelenen çerçeve yazılmıyor); bkz. R2-C-3 artığı |
| C-15 | DÜŞÜK | **DÜZELTİLMİŞ** | MaxCommits kesilmesinde `goodPos` artık kaydediliyor |
| C-16 | BİLGİ | **GEÇERLİ** | Sayfa LSN damgası hâlâ yazılıyor ama hiçbir yerde okunmuyor/doğrulanmıyor (C-3'ün önlemi eklenmemiş) |

**Skor:** 5 DÜZELTİLMİŞ (C-2 kısmen, C-6, C-13, C-14, C-15), 11 GEÇERLİ (C-1, C-3, C-4, C-5, C-7 … C-12, C-16), 0 GEÇERSİZ.

---

### C-1 — KRİTİK — GEÇERLİ (düzeltilmedi)

Mekanizma değişmemiş; güncel kanıtlar:

1. Commit veri dosyasına hiçbir şey yazmaz: `VDbPageEngine.pas:1061-1063` ("Veritabani dosyasina bu noktada HICBIR SEY yazilmaz"), DoCommit yalnız `FWal.AppendFrame` + `FWal.Commit` (`1009-1063`).
2. Tazelemede başka process'in imajları TEMİZ kurulur:
   - `VDbPageStore.pas:2198-2210` (LoadFrame, AImage dalı): `Dirty := False` — "diskteki surum yazarin commit'inde guncellenir" varsayımı hâlâ yanlış (yazar commit'te diske yazmaz).
   - `VDbPageStore.pas:3016-3022` (InstallPage, mevcut çerçeve, AViewOnly): "Temiz cerceve temiz kalir"; `3069-3090`: yalnız `isNew` sayfalar kirli.
3. Checkpoint yalnız kirli çerçeveleri yazar: `VDbPageStore.pas:2743-2749` (`if ... FFrames[i].Dirty then WritePageAt`).
4. Truncate tüm gövdeyi siler, LSN filtresi yok: `VDbPageWal.pas:960` (`FStream.Size := VDB_PAGE_SIZE`).
5. Budama bariyeri yalnız WAL fsync'ini garantiler, veri dosyasına inişi değil: `VDbPageEngine.pas:1125-1133` (`FStore.Flush(DoSync)` → `AwaitDurable(FWal.WrittenLsn)` → `FWal.Truncate(FStore.LSN)`).
6. MinLSN atlama: `VDbPageWal.pas:815-823` (`lsn <= MinLSN` → `Continue`).
7. Okuma yolunda bayatlık denetimi yok: `VDbPageStore.pas:2255-2282` (GetPageInternal yalnız `PageVerify` yapı+CRC).

Senaryo (eski raporla aynı): A commit eder (LSN 105, WAL fsync'li) → B tazelemeyle sayfayı temiz kurar (`VDbPageEngine.pas:404/447` → `ApplyRecoveredView` → `InstallPage(..., True)`, `754-757`) → B kapanır (`591-642`: `AcquireDataWrite` → `Checkpoint(True)`) → Flush temiz çerçeveyi atlar, `Truncate` 105'i siler → A çökerse onaylı commit **kalıcı olarak kaybolur**. Önbellek tahliyesi varyantı da duruyor: `VDbPageStore.pas:2179-2197` (temiz kurban sessizce düşer).

**Sayfa LSN damgası doğrulaması (C-16) EKLENMEMİŞTİR** — `VDbPage.pas:65` (LSN alanı), `VDbPage.pas:196` (`PageInit` 0 yazar); v3 okuma/yazma yolunda hiç okunmuyor.

### C-2 — KRİTİK — KISMEN DÜZELTİLMİŞ

**Düzeltme (çalışma ağacında, commit edilmemiş):** `VDbBackendV3.pas:3925-3962` — `SwapDbFileWith` artık `.gen` offset 8'deki durabil LSN'i **0'a çekiyor** (`3935-3944`: TFileStream ile yazım + `VDbFlushStream`), nesil sayacını (offset 0) koruyor; sıfırlama başarısız olursa `.gen`'i siliyor, o da olmazsa açık hata veriyor (`3953-3961`) ve çağıran `.bak`'a dönüyor (`3978-4001`). Yeni motor `Open`'da `FDurableLsn := FStore.DurableLsn` (`VDbPageEngine.pas:477`) ile artık 0'dan başlar. VACUUM (`3666`), RESTORE (`3595`), REKEY (`3739`) üçü de bu ortak yoldan geçer. **Bu düzeltme sağlam:** monoton `SetDurableLsn`'i (`VDbPageStore.pas:1259-1273`) bilerek bypass ediyor ve kalıcı kılıyor.

**Kalıntı (senaryo 5 — GEÇERLİ):** `VDbPageStore.pas:1845-1865` (OpenEx): `.gen` ≥ 16 baytsa içindeki değerler **korunur**. DB silinip (veya `.odb`+`.wal` kopyalanıp) aynı yolda yeniden yaratıldığında bayat yüksek durabil LSN yaşar → `AwaitDurable` (`VDbPageEngine.pas:892-899`) fsync'i atlar → fsync'siz "durabil" onayı. Ayrıca `.gen`'i **kopya ile birlikte** taşıyan dizin klonları aynı açığı taşır. Öneri: OpenEx'te veri dosyasının "nesil" kimliğini (yaratılış damgası/meta LSN tabanı) `.gen` ile karşılaştırmak; uyuşmazsa offset 8'i sıfırlamak.

**Şüpheli artık (düşük olasılık):** çok süreçli ortamda eski uzayda `SetDurableLsn`'in bayat değeri geri yazması; pratikte `RenameFile`'ın açık handle'lara (`fmShareDenyNone`, `FILE_SHARE_DELETE` yok) takılması yüzünden swap sırasında ikinci process bulunamaz — bu yüzden kapatılmış sayılır ama doğrulanmamıştır.

### C-3 — KRİTİK — GEÇERLİ

C-1'in mekanizma kanıtlarıyla birebir aynı zincir; ek kanıt yok, ek önlem de yok:
1. Temiz kurulum: `VDbPageStore.pas:2198-2210`, `3016-3022`, `3069-3090`.
2. Tahliyede sessiz düşürme: `2179-2197` (temizse hiçbir şey yazılmaz).
3. Geri okuma diskten: `2227` (`ReadPageAt`) — sürüm eski.
4. Sonraki tazelemede atlama: `VDbPageEngine.pas:447` (`MinLSN = FStore.ViewLsn`) → `VDbPageWal.pas:815-823`.
5. Okumada damga denetimi yok: `VDbPageStore.pas:2255-2282`, `VDbPage.pas:65/196` (C-16).

Çalışma zamanı sessiz veri ezilmesi; crash gerektirmez.

### C-4 — YÜKSEK — GEÇERLİ

- `VDbPageWal.pas:487` (`Refresh`): `FWrittenLsn := FLSN;` — başlık (checkpoint) LSN'i; gövdedeki sonraki kayıtlar sayılmaz. Değer kasıtlı olarak düşer.
- `VDbPageWal.pas:916` (`Recover` sonu): `FWrittenLsn := FLSN` — MinLSN ile atlanan kayıtlar işlenmediği için sayılmaz.
- `VDbPageEngine.pas:905`: `target := FWal.WrittenLsn` — hedef düşükse `FDurableLsn` bekleyenin LSN'ine asla ulaşamaz (döngü `886-969`).
- Ek etki: `VDbPageEngine.pas:1132` `AwaitDurable(FWal.WrittenLsn)` checkpoint bariyeri de eksik hedeflenir → gövdedeki fsync'lenmemiş kayıtlar `Truncate` (`VDbPageWal.pas:960`) ile silinebilir (C-1 ile birleşir).
- Truncate'ın kendi yorumu (`VDbPageWal.pas:954-956`) tehlikeyi bilir; Refresh tam olarak aksini yapar.

### C-5 — YÜKSEK — GEÇERLİ (+ yeni örnekler)

- `VDbPageEngine.pas:1106-1146` (`Checkpoint`) hâlâ hiçbir kilit almaz.
- Kilitsiz/eksik kilitli çağrı yerleri (güncel):
  - `VDbBackendV3.pas:3629` (Compact), `3578` (RestoreFrom), `3702` (Rekey): yalnız `FEngCs`; süreçler arası `AcquireDataWrite` yok.
  - `VDbPageEngine.pas:1181-1182` (Verify): hiçbir kilit yok.
  - **YENİ örnek 1:** `VDbBackendV3.pas:3515` (BackupTo) — `FEngCs` içinde kilitsiz `Checkpoint(True)` + `CopyCommittedTo`; yedek dosyası, kopya sırasında başka process'in commit ettiği sayfaları içermeyebilir.
  - **YENİ örnek 2:** `VDbBackendV3.pas:846` (EnsureLogBase) — taban imaj için kilitsiz `Checkpoint(True)`.
- Doğru örnek: `VDbPageEngine.pas:616-618` (Close) ve `VDbBackendV3.pas:2936` (CommitBatch) `AcquireDataWrite` alır; `AcquireDataWrite` → `RefreshIfStaleForce` (`VDbPageStore.pas:1686`).

### C-6 — YÜKSEK — DÜZELTİLMİŞ (bir artığı var: R2-C-2)

Çalışma ağacında düzeltildi: `VDbBackendV3.pas:2895-2897`, `3018-3040` (`LogFinish`/`MaybeCheckpoint`/`MaybeAutoCompact` istisnası `pendExc` ile yakalanır), `3049-3066` (kilitler bırakıldıktan sonra `AwaitDurable(syncLsn)` GARANTİ), `3070-3071` (asıl istisna yeniden yükseltilir). `AcquireExceptionObject` deseni doğru; `ReleaseWriteHold` finally'de (`3072-3074`).
Ayrıca eski yanlış yorum düzeltildi: `VDbBackendV3.pas:977-981` — artık "commit WAL'e yazildi ancak fsync HENUZ yapilmadi" diyor.
**Artık:** `3055-3065` — `pendExc` varken ikincil `AwaitDurable` (fsync) hatası yutuluyor (bkz. R2-C-2).

### C-7 — YÜKSEK — GEÇERLİ

`VDbPageEngine.pas:343-467` (StoreRefreshed): tam yolda `396 FStore.DropCache` (açık işlemin kirli sayfalarını yok eder) ve `408 InstallPending(True)` + `ClearPending` (`1099-1104`) korumadan ÖNCE; koruma `421-424` / `460-463` hâlâ sonra. `FPendingCount` kontrolü hâlâ dead-code (ClearPending listeyi boşalttı). DoCommit adım 2'nin `Mark = FStore.TxnId` filtresi (`1021-1023`) + view kurulumda `TxnMark := 0` (`VDbPageStore.pas:3021/3087`) → kısmi/kaybolan commit riski sürüyor. "Şüpheli" niteliği aynen korunur (backend yolu kilitli; risk motor API'sini doğrudan kullanan oturumlarda).

### C-8 — YÜKSEK (şüpheli) — GEÇERLİ

`VDbPageWal.pas:771-778` (Recover): `hdrLsn := FLSN` bellek-içidir, disk başlığı okunmaz; `FScanPos <= FStream.Size` yalnız küçülmeyi yakalar. `Refresh` (`473-492`) `FScanPos`'u sıfırlamaz. Değişiklik yok.

### C-9 — ORTA — GEÇERLİ

`VDbPageWal.pas:304-305` (`WriteHeader` tek `WriteBuffer`), `339-340` (`ReadHeader` CRC bozuksa raise), `432-437` (`Open` istisnayı yeniden fırlatır), `VDbPageEngine.pas:480` yakalamaz → açılış tamamen başarısız. Truncate'taki aynı pencere: `VDbPageWal.pas:960-963`. "Bozuk WAL başlığı = atılabilir WAL" toleransı eklenmemiş.

### C-10 — ORTA — GEÇERLİ

`VDbPageWal.pas:787-848` (TornTail := True + Break), `917` (`FScanPos := goodPos` — bozulma noktasında takılı kalır), `Stats` yalnız `FWalStats`'a yazılır (`VDbPageEngine.pas:405/448/508`); uyarı/istisna yok. `CommitCount` (`VDbPageWal.pas:922-941`) TornTail'de eksik sayar.

### C-11 — ORTA (şüpheli) — GEÇERLİ

`VDbBackendV3.pas:2435` (`FEng.Wal.CommitCount` kilitsiz), `2457-2459` (`CopyBaseImageTo` + `AsOfCopyFile` — `FEngCs` dışında, süreçler arası yazma kilidi yok). Değişiklik yok; ek risk bkz. R2-C-4.

### C-12 — ORTA — GEÇERLİ

Sıralama değişmedi: `CommitBatch` → `3013 CommitNoSync` (WAL yazımı, fsync yok) → `3022 LogFinish` → `VDbChangeLog.pas:941-942` (`FSyncGroups` ise fsync) → `3054 AwaitDurable` (WAL fsync). `FDurableChangeLog=True` iken günlüğün kalıcı kopyası WAL fsync'inden önce var olur; çökmede CDC/PITR hayalet commit görebilir. Yalnızca `VDbBackendV3.pas:977-981`'deki yanlış "commit zaten durabil" yorumu düzeltildi (iyi), davranış aynı.

### C-13 — DÜŞÜK — DÜZELTİLMİŞ

`VDbPageWal.pas:967-980` (`Bytes`): `FWalEncrypted` ise `payLen := VDB_ENC_ENVELOPE`, değilse `VDB_PAGE_SIZE`. `MaybeCheckpoint` eşiği (`VDbBackendV3.pas:1615-1625`) artık şifreli modda doğru ölçülür.

### C-14 — DÜŞÜK — DÜZELTİLMİŞ (bir artığı var: R2-C-3)

`VDbPageWal.pas:699-712`: `VDbFlushStream` istisnasında `FBufferCount := 0; BufHashClear; SetLength(FOutBuf, 0); raise;` — yinelenen çerçeve/sıfır-yük yazımı sorunu kapandı. Ancak kayıtlar dosyada kalmaya devam eder (bkz. R2-C-3).

### C-15 — DÜŞÜK — DÜZELTİLMİŞ

`VDbPageWal.pas:885-891`: MaxCommits kesilmesinden önce `goodPos := FStream.Position` artık kaydediliyor; çift sayım giderildi.

### C-16 — BİLGİ — GEÇERLİ

`VDbPage.pas:65` LSN alanı, `VDbPage.pas:196` `H^.LSN := 0`; v3 yolunda hiçbir okuma/karşılaştırma yok (yalnız v2: `VDbCore.pas`). C-3'ün önerilen önlemi (sayfa LSN'i > ViewLsn ise reddet/WAL'e bak) uygulanmamış.

---

## KISIM 2 — YENİ BULGULAR (R2-C-1 …)

### R2-C-1 — YÜKSEK: Yarım VACUUM + yutulan istisna → `AwaitDurable` sonsuz fsync döngüsü (kilitli kalmadan asılı kalma)

**Dosya:satır:** `VDbBackendV3.pas:3841-3875` (MaybeAutoCompact istisnayı yutar: `3868-3871` → `Result = False`), `3612-3677` (Compact: `3666 SwapDbFile(tmp)` **sonrası** `3670 VDbFileBytes`, `3673 EnsureLogBase` → `846 FEng.Checkpoint(True)`, `ForceDirectories`, kopya — hepsi istisna atabilir), `3033-3034` (`if MaybeAutoCompact then syncLsn := 0` — yarım başarıda **atlanır**), `3051-3054` (`FEng.AwaitDurable(syncLsn)` — YENİ motorda ESKİ uzaydan LSN).

**Mekanizma:** `MaybeAutoCompact` içinde `AutoCompactBody` dosya değişimini tamamlar (`SwapDbFile` yeni motoru kurar) ama hemen ardından bir istisna fırlatır (örn. `EnsureLogBase`'te fsync/dizin/kopya hatası). İstisna yutulur, `Result = False` döner, `syncLsn` sıfırlanmaz. `CommitBatch` sonra `AwaitDurable(eski syncLsn)` çağırır: `VDbPageEngine.pas:885-969` döngüsünde `FDurableLsn >= ALsn` **asla** gerçekleşemez (yeni motorun WrittenLsn'i ~1-5; hedef ~1.000.000) → her turda `SyncDurable` → **sonsuza kadar fsync fırtınası, yanıt dönmez** (v3.24 yorumundaki "70.000 fsync/s, ilerleme yok" semptomunun farklı tetikleyicisi).

**Çalışma ağacı etkileşimi (önemli):** C-2 düzeltmesinden önce bayat `.gen`'deki yüksek durabil LSN bu döngüyü *tesadüfen* kurtarıyordu (`shared >= ALsn` → Exit — ama bu da yanlış-durabil onayıydı). `.gen` sıfırlaması bu "kurtuluşu" kaldırdı: artık yanlış-durabil yerine **asılı kalma** görülür. Bu yüzden bulgu, commit edilmemiş değişiklikle **daha görünür** hâle geldi.

**Not:** Yol önceden de vardı (C-6 düzeltmesiyle eklenmedi) ama eski raporda yer almıyor. "Şüpheli": tetik için swap sonrası istisna gerekir; ancak `EnsureLogBase` her VACUUM'da çalışır ve fsync hataları gerçek bir senaryodur.

**Öneri:** `MaybeAutoCompact`'e "dosya değişimi tamamlandı" bayrağı ekleyip istisna olsa bile sonucu döndürmek; veya `CommitBatch`'te `AwaitDurable` hedefini motor-nesnesi ile doğrulamak (hedef > WrittenLsn ise doğrudan bekleme — zaten durabil).

### R2-C-2 — ORTA: C-6 düzeltmesi ikincil fsync hatasını yutuyor → yanlış durum raporlama (çalışma ağacından YENİ)

**Dosya:satır:** `VDbBackendV3.pas:3055-3065` (`pendExc` doluyken `tmpExc := AcquireExceptionObject; tmpExc.Free` — `AwaitDurable` hatası **yok sayılır**).

**Senaryo:** `LogFinish` hata verir (`pendExc` = "değişim günlüğü yazılamadı") + `AwaitDurable` **başarısız olur** (WAL fsync hatası). İstemci yalnız günlük hatasını görür; "günlük eksik ama veri WAL'de durabil" sonucuna varabilir — oysa fsync **olmamıştır** ve crash'te onaylı veri kaybolabilir. Yorum (`3056-3057`) "asıl commit hatası korunur" diyor ama günlük hatası bir commit hatası değildir; dayanıklılık hatasının buharlaşması yanlış "durabil" algısı üretir (eksenin "yanlış durabil raporlama" teması).

**Öneri:** İkincil hata en azından `FLogProblem`/`LastAutoCompactError` benzeri bir alana yazılmalı; ya da `pendExc` bir "commit sonucu belirsiz" sarmalayıcısıyla birleştirilip iki hata da raporlanmalı.

### R2-C-3 — ORTA: Başarısız raporlanan commit'in WAL kaydı geri alınmıyor → kurtarmada "hayalet commit"

**Dosya:satır:** `VDbPageWal.pas:692` (`WriteBuffer` — kayıt/kayıtlar dosyaya zaten geçti), `622-627` (`Rollback` yalnız tamponu temizler; dosyadaki bytes'a dokunmaz), `VDbBackendV3.pas:3038-3040` + `3070-3071` (istisna sonrası akış `AbortBatch`'e kadar WAL'i **kesmez**).

**Mekanizma:** `FWal.Commit` içinde fsync istisnasında (C-14 fix sonrası) tampon temizlenir ve istisna yükselir; ancak çerçeveler + **tam commit kaydı** dosyadadır. İstemci hatayı "işlem uygulanmadı" diye yorumlar ve işlemi iptal eder/geri alır; fakat WAL kaydı kalır. Makine çökerse kurtarma bu kaydı tam ve CRC-düzgün bulur ve **iptal edilmiş işlemi uygular**. Aynı yapı, C-6'nın "istisna sonrası uygulanmış ama hata raporlanmış commit" durumunun ikinci yüzüdür; bu kez mekanizma WAL'de kalan artık kayıttır.

**Not:** "Şüpheli" değil — kod yolu açık; tetik için fsync hatası (veya C-6 yolunda LogFinish/MaybeCheckpoint istisnası + sonradan crash) gerekir. Öneri: bu yollarda `AbortBatch`/hata yolunda WAL'i son-iyi-konuma (`goodPos` benzeri) geri çekmek ya da API'de "sonucu belirsiz" ayrı hata tipi bildirmek.

### R2-C-4 — DÜŞÜK: `CommitCount` kilit dışı `Recover`, tarama imleçlerini (FScanPos/FScanHdrLsn) yan etkiyle değiştirir

**Dosya:satır:** `VDbBackendV3.pas:2415, 2435` (`FEng.Wal.CommitCount` — `FEngCs` dışında), `VDbPageWal.pas:922-941` (`CommitCount` → `Recover(nil, st)`; `FLSN`/`FWrittenLsn` geri konur ama `917-918`'deki `FScanPos`/`FScanHdrLsn` **geri konmaz**).

**Etki:** AS OF sayımı ile eşzamanlı tazeleme (`StoreRefreshed` → `Recover`, artımsal) aynı WAL nesnesinin imleçlerini yarışla değiştirir; artımsal tarama yanlış konumdan sürebilir (C-8/C-10 ile birleşince sessiz atlama). "Şüpheli" (eşzamanlı thread gerektirir). Öneri: `CommitCount`'ta imleçleri de kaydet/geri yükle veya kilit altına al.

### R2-C-5 — DÜŞÜK: Taşma zinciri geri alımı / adım sınırı yarım bırakma (çalışma ağacından YENİ, R-A-3/R-A-4)

**Dosya:satır:** `VDbPageHeap.pas:493-509` (WriteOverflow `except` — en iyi çaba geri alma, iç istisna yutulur), `605-608` (FreeOverflow adım sınırında `Exit` — zincirin kalanı **serbest bırakılmaz**, sayfa sızıntısı), `541-548` (ReadOverflow sınır aşımında `Result = False`).

**Etki:** Veri kaybı yok; bozuk/kendine dönen zincirde sayfa sızıntısı ve sessiz okuma hatası. Butünlük açısından kabul edilebilir (sonsuz döngü/çökme yerine güvenli çıkış doğru yönde); yalnız sızıntı bilinmeli.

### R2-C-6 — BİLGİ: Executor batch çağrılarının `FT.*` sarmalayıcısına taşınması (çalışma ağacından)

**Dosya:satır:** `VDbExecutor.pas:15650, 16214, 17980, 18224` (`FT.Backend.BeginBatch/CommitBatch` → `FT.BeginBatch/CommitBatch`). `FT.*` sarmalayıcıları sema anlık görüntüsü + auto-inc sayac boşaltımı + sema kaydı ekler (`VDbTable.pas:6395-6419`); commit/abort simetrik. Dayanıklılık sıralamasını değiştirmez (commit yine `FKvB.CommitBatch` → `VDbBackendV3.CommitBatch`). İncelemede eksen riski görülmedi.

---

## Çalışma ağacı değişikliklerinin Eksen C karnesi (özet)

| Değişiklik | İlgili bulgu | Değerlendirme |
|---|---|---|
| `SwapDbFileWith` `.gen` offset 8 sıfırlama (`VDbBackendV3.pas:3925-3962`) | C-2 | Sağlam; kalıntı senaryo (yeniden yaratma/kopya) açık |
| `CommitBatch` istisna + garanti `AwaitDurable` (`3018-3071`) | C-6 | Doğru; ikincil hata yutuluyor (R2-C-2) ve R2-C-1 ile etkileşim var |
| `WAL.Commit` fsync istisnası tampon temizliği (`VDbPageWal.pas:699-712`) | C-14 | Doğru; hayalet-commit yönü açık (R2-C-3) |
| `Recover` MaxCommits `goodPos` (`885-891`) | C-15 | Doğru |
| `Bytes` şifreli çerçeve boyu (`967-980`) | C-13 | Doğru |
| `AwaitDurable` B-18 try/finally (`VDbPageEngine.pas:940-960`) | — | Doğru; kilit-bekleme sıkışmasını kapıyor |
| `VDbPageStore` R-A-11 kilit init (`VDbPageStore.pas:185-187, 660-665, 711-712`) | — | Doğru; yarım kurulumda Destroy güvenli |
| `VDbPageHeap` R-A-3/R-A-4 (`446-548, 596-608`) | — | Doğru yön; sızıntı R2-C-5 |
| `VDbTable` B-3/B-4/B-11 + `VDbExecutor` B-8/FT.* | — | Eksen dışı; B-3 önbellek sıfırlama noktaları tam (7861-7864, 8002-8003, 9426-9427, 9601-9614) |

**Dokunulmayan KRİTİK üçlü:** C-1, C-3 ve C-16'nın kök nedeni (view imajlarının temiz kurulması + Truncate'ın filtresiz budaması + okuma yolunda LSN damgası denetimsizliği) **aynen duruyor.** En kritik düzeltme önerisi değişmedi: tazelemede kurulan view imajlarını kirli işaretlemek ya da Checkpoint'te "ViewLsn'den yeni ama dosyaya yazılmamış" sayfaları Flush'a dâhil etmek; `Truncate`'ı yalnızca gerçekten yazılmış LSN'e kadar budamak.
---

# EK-D — alt ajan tam raporu

# Kod İnceleme Raporu 2 — Eksen D: İşlevsel Doğruluk Hataları ve Sınır Durumları

- **Dal / commit (HEAD):** `v3` @ `1fe0acf`
- **ÇALIŞMA AĞACİ KİRLİ:** 7 dosyada commit edilmemiş çalışma var — `VDbBackendV3.pas`, `VDbExecutor.pas`, `VDbPageEngine.pas`, `VDbPageHeap.pas`, `VDbPageStore.pas`, `VDbPageWal.pas`, `VDbTable.pas`. Bu rapor **çalışma ağacının güncel hâlini** inceler; satır numaraları bu hâle aittir.
- **Tarih:** 2026-11-06
- **Mod:** Salt okunur. Hiçbir dosya değiştirilmedi, derleme/çalıştırma yapılmadı.
- **Kapsam:** (1) `tmp64\r_D.md` raporundaki 9 bulgu + P-67 teşhisinin güncel koda karşı tek tek doğrulanması; (2) aynı eksende yeni denetim — özellikle commit edilmemiş değişikliklerin (B-3/B-4/B-8/B-11 ve sayfa katmanı C-/R-A- yamaları) doğruluk riskleri.

---

## KISIM 1 — Eski iddiaların kaderi

| # | Eski iddia (r_D.md) | Kader | Güncel kanıt |
|---|---|---|---|
| 1 | P-67 teşhisi: "FBatchHas* hiç okunmuyor, çağrılar koşulsuz" | **GEÇERSİZ** (rapor zaten düzeltmişti) | Bayraklar koşullu okunuyor: `VDbTable.pas:10583-10587` (`if FBatchHasIdentity then ApplyIdentity`, `if FBatchHasGenerated then VDbApplyGenerated`). Tanım: `394-395`. |
| 2 | **D-1a [KRİTİK]: DDL-inside-batch sonrası bayat FBatchTableDef/FBatchHas* önbelleği** | **GEÇERLİ — aynen sürüyor** (bkz. §1a) | `VDbTable.pas:10455-10458` (Path 2 bayat okuma), `5992-6001` (MarkSchema `ResetBatchTableCache` ÇAĞIRMAZ), `9015-9025` (AlterAddColumn `ownDdl=False`), `6376-6393` (ResetBatchTableCache yalnız 7 çağrı noktasında: `5164, 6328, 6370, 6402, 6409, 6429, 6452`) |
| 3 | D-1b: literal "non-batch B araya girme" senaryosu erişilemez; eşzamanlılık varyantı ŞÜPHELİ | **GEÇERSİZ / ŞÜPHELİ** (değişmedi) | Non-batch Insert `inBatch := FKvB.InBatch` (`10432`) ve `FBatchTableCached` yalnız batch'te kurulur (`10475`); batch sınırları `ResetBatchTableCache` çağırır. |
| 4 | D-Y1 [YÜKSEK]: SUM/AVG Double hassasiyeti >2^53 (`VDbSql.pas`) | **GEÇERLİ** (satır kayması yok) | `VDbSql.pas:2308` (`fv, sum: Double`), `2356-2357` (Int64→Double biriktirme), `2367` (`Trunc(sum)`), `2371-2372` (`Round(sum) mod/div cnt`). `VDbSql.pas` değişmedi. |
| 5 | D-Y2 [YÜKSEK]: pencere/toplu SUM/AVG da Double + hepsi-float ayrıştırma | **GEÇERLİ** | `VDbExecutor.pas:8211` (`sum: Double`), `8430-8433` (`VDbParseFloat` ile biriktirme), `8442` (`sum / navg`). Bölge değişmedi. |
| 6 | D-Y3 [ORTA]: `try FT.AbortBatch; except end;` yutma | **GEÇERLİ — ve kapsamı BÜYÜDÜ** | Artık **iki** örnek var: `VDbExecutor.pas:17117` (eski 17104, +13 satır kaydı) ve `VDbSql.pas:3271`. Eski raporun "tek örneği" notu geçersiz. |
| 7 | D-Y4 [DÜŞÜK]: AutoInc/MaxPkInt `+1` Int64 taşması | **GEÇERLİ** (satır güncellendi) | `VDbTable.pas:6098` (`AutoIncOf(T) + 1`), `6102` (`MaxPkInt(T) + 1`), `10597`, `10609-10611`, `10616-10618`. |
| 8 | D-Y5 [DÜŞÜK]: `VDbNormValue` tarih locale-fallback | **GEÇERLİ** | `VDbTable.pas:1945-1965`; `TryStrToDate(v, d)` fallback `1949`. |
| 9 | D-B1 [BİLGİ]: tip çıkarsamada `try GetTable except Exit` | **GEÇERLİ** | `VDbExecutor.pas:3047-3051`. |
| 10 | D-B2 [BİLGİ]: `VDbIdxCmp` NULL başta (PostgreSQL'den farklı) | **GEÇERLİ** (tasarım tercihi) | `VDbTable.pas:1989`. |

### §1a. D-1a tetik dizisi — güncel kodda adım adım yeniden kurulumu [KRİTİK, GEÇERLİ]

```sql
BEGIN;
INSERT INTO A(a) VALUES(1);
ALTER TABLE A ADD COLUMN g INT GENERATED ALWAYS AS (a*2) STORED;
INSERT INTO A(a) VALUES(2);
COMMIT;
```

1. `BEGIN` → `TVTableDb.BeginBatch` (`6395-6404`) → `ResetBatchTableCache` (`6376-6393`): tüm `FBatch*` temiz.
2. 1. `INSERT` → `Insert` (`10413`) `inBatch=True`; `FBatchTableCached=False` olduğu için **Path 3** (`10462-10488`): `FBatchTableDef := GetTable('A')`, `FBatchHashPrefix` ve `FBatchHasIdentity/FBatchHasGenerated` (`10482-10488`) hesaplanır — ALTER öncesi şema, `FBatchHasGenerated=False`.
3. `ALTER` → `ExecAlterTable` → `AlterAddColumn` (`8926-9026`): `ownDdl := not FKvB.InBatch` = **False** (`9015`) → `BeginBatch/CommitBatch` **çağrılmaz** → `ResetBatchTableCache` tetiklenmez. `MarkSchema` (`9020` → `5992-6001`) yalnız `FOpenTDefValid := False` yapar (`5996`) — **batch önbelleklerine dokunmaz**; `FSchemaDirty := True` ile yetinir (`5997-5998`). `FTables` yeni şemayla güncellenir (`9019`) ama `FBatchTableDef` bayat kalır.
4. 2. `INSERT` → **Path 2** (`10455-10458`): `inBatch and FBatchTableCached and (FBatchTableDef.Name = Table)` → `tp := @FBatchTableDef` (Eski şema). Yeniden hesaplama YOK.
5. `10583-10587`: `FBatchHasGenerated=False` → `VDbApplyGenerated` **atlanır** → `g` hesaplanmaz. Satır eski kolon sayısıyla kodlanır; `DecodeRow` satır başlığındaki `H.ColCount` ile kendini tanımlar → OOB olmaz ama `SELECT *` yeni şemada eksik/kayık kolon üretir = **yanlış sorgu sonucu**. 2. INSERT'te `g` kolonu listelenirse `FindCol` bayat tanımda bulamaz → `kolon yok: g` (`10561`).
6. **Ek hasar (eski raporda yok):** `FBatchColMapValid` + `FColMapTable` de DDL ile geçersiz kılınmaz (`10539-10551`); `FBatchHasPkIdx` da bayat kalır (`10480`). `CREATE INDEX`/`DROP INDEX` içeren varyant bkz. R2-D-2.
7. **Kapsam:** Non-batch yol (Path 1/4) etkilenmez — tek başına DDL `ownDdl=True` ile kendi batch'ini açar (`9016`) ve `CommitBatch` `ResetBatchTableCache` çağırır (`6409`). Hata yalnız **batch yolu (Path 2)** ile sınırlı. Commit edilmemiş B-4 yaması yalnız non-batch `FOpenTDef` önbelleğini korur (`5996`); D-1a'yı **hafifletmez**.

---

## KISIM 2 — Yeni bulgular (R2-D-…)

### [R2-D-1] [KRİTİK] B-11 yaması: `PutRow` `FPrefixCacheName`'i bayrakları yeniden hesaplamadan yazıyor — sonraki INSERT'te IDENTITY/GENERATED atlanır
- **Dosyalar:** `VDbTable.pas:7113-7117` (B-11, commit edilmemiş), `10440-10452` (Path 1 bayrak atlama koşulu), `10496-10516` (B-4 / Path 4), `10583-10587` (bayrak okuma).
- **Mekanizma:** `Insert` yolları `FPrefixCacheName`'i **yalnızca** `FBatchHasIdentity/FBatchHasGenerated` taramasıyla birlikte günceller (`10445-10451`, `10482-10488`, `10509-10515`). Atlanma koşulu `FPrefixCacheName = tp^.Name` olduğundan kod, "FPN=X ise bayraklar X'in" **değişmezini** varsayar. Commit edilmemiş B-11 bu değişmezi **kırar**: `PutRow` (`7089`) `FPrefixCacheName := T.Name` yazar ama bayrakları **dokunmaz** (`7114-7117`).
- **Erişilebilir tetik (2 yeterli, tek oturum, otomatik-transaction):**
  ```sql
  CREATE TABLE p(id INT PRIMARY KEY);
  CREATE TABLE a(x INT PRIMARY KEY IDENTITY, ref INT REFERENCES p(id) ON UPDATE CASCADE,
                 g INT GENERATED ALWAYS AS (x*2) STORED);
  INSERT INTO p VALUES (1);
  UPDATE p SET id=7 WHERE id=1;    -- FK kaskad → PutRow(a satırları): VDbTable.pas:7319/7331
                                   -- → 7114-7117: FPrefixCacheName='a', bayraklar hâlâ False/False
  INSERT INTO a(ref) VALUES (7);   -- Path 1 (P-55 @td): 10440'ta 'a'='a' → bayrak taraması ATLANIR
                                   -- → 10586: VDbApplyGenerated atlanır → g = '' (boş) yazılır
  ```
  `PutRow`'a giden diğer yol: updatable view insert (`11613`). İki-tablo varyantı da geçerli: `INSERT b` (bayraklar b'nin) → kaskad `PutRow(a)` (FPN='a') → `INSERT a` (atlama → b'nin bayrakları).
- **Etki:** GENERATED kolon sessizce hesaplanmaz, satır `g=''` ile **kalıcı olarak yanlış yazılır** (yanlış sorgu sonucu). IDENTITY-PK durumu `pk=''` oto-sayac yoluna (`10606-10614`) düşüp kendini onarır; IDENTITY-PK-olmayan kolon sessiz boş kalır. Şiddet: **KRİTİK** (sessiz veri bozulması, gündelik erişilebilir dizi).
- **Not:** Commit edilmemiş bir yamadan kaynaklanır; `HEAD`'de yoktur. En dar düzeltme: `PutRow`'daki B-11 bloğunda `FPrefixCacheName` yazarken `FBatchHasIdentity/FBatchHasGenerated`'ı da yeniden tara (veya bayrakları `False` yapıp Insert'teki taramayı ad-eşleşmesi yerine bayrak-geçerlilik bayrağına bağla).

### [R2-D-2] [YÜKSEK] D-1a'nın indeks varyantı: batch içinde CREATE/DROP INDEX sonrası `FBatchTableDef.Idx` bayat — yeni satır indekse işlenmez → indeks taraması satırı kaçırır
- **Kanıt:** `CreateIndexCols` indeksi mevcut satırlardan **CREATE anında** kurar: `FTables.AddOrSetValue` + `MarkSchema` + `BuildOneIndex(t, High(t.Idx))` (`9888-9896`, multi-col `9924-9925/9952-9960`). `MarkSchema` batch önbelleğini sıfırlamaz (§1a). Sonraki INSERT `Path 2`'den `FBatchTableDef` ile `IdxAddRow`'a gider; `IdxAddRow` yalnız `for j := 0 to High(T.Idx)` döner (`7827`) — bayat `T.Idx`'te yeni indeks **yoktur** → satır `FIdxOps`'a hiç düşmez.
- **Tetik:** `BEGIN; INSERT INTO A VALUES(...); CREATE INDEX ix ON A(x); INSERT INTO A VALUES(...); COMMIT;` → 2. satır indekste yok; `SELECT ... WHERE x=...` indeks yoluyla satırı **bulamaz** = yanlış sorgu sonucu. Ters yönde (DROP INDEX sonrası bayat `T.Idx` ile `IdxAddRow`) silinmiş indeks anahtarına beklenen işlem yazılır; `FreeIdxUniqMaps` sonrası `FIdxUniq` dokunumu zararsız ama `FIdxOps` artık yığılır — taşma/dolambaç riski (**şüpheli**, tek başına doğrulanmadı).
- **Şiddet:** YÜKSEK (indeks yolu yanlış sonuç; tablo taraması doğru sonucu verir, bu yüzden kısmen maskelenir). Düzeltme önerisi D-1a ile aynı: her şema değişikliğinde `ResetBatchTableCache`.

### [R2-D-3] [ORTA] FK kaskadı batch simetrisizliği: commit `FKvB.CommitBatch`, abort `TVTableDb.AbortBatch`
- **Kanıt:** `VDbTable.pas:7305-7337`: `ownBatch := not FKvB.InBatch; if ownBatch then FKvB.BeginBatch` (`7306`) ve `FKvB.CommitBatch` (`7334`) — ama `except` dalı `TVTableDb.AbortBatch` çağırır (`7336`).
- **Neden yanlış:** Commit kolu `TVTableDb.CommitBatch`'in işlerini atlar: `FlushAutoIncCache` (`6408`), `ResetBatchTableCache` (`6409`), `FSchemaDirty` yazımı (`6410-6411`), `ClearSavepoints`/`ClearSchemaSnapshot` (`6413-6414`). Bu koşullar altında (DDL'siz kaskad) pratikte sessiz veri kaybı üretmez; ancak kaskad PutRow'larının `FPrefixCacheName` kirletmesi (R2-D-1) bu simetrisizlik yüzünden batch dönüşünde de temizlenmez. Abort kolu tam `AbortBatch` (tüm indeksleri yeniden kurar, `6443-6446`) — davranış farkı tutarsız.
- **Şiddet:** ORTA (simetrisizlik + R2-D-1'i kalıcılaştırma).

### [R2-D-4] [DÜŞÜK] Commit yolunda ikincil `AwaitDurable` hatası sessizce serbest bırakılıyor (C-6)
- **Kanıt:** `VDbBackendV3.pas` (commit edilmemiş C-6 bloğu, ~`3046-3070`): `if pendExc = nil then pendExc := ... else begin tmpExc := ...; tmpExc.Free; end;` — ikinci hata yutulur. Ayrıca `raise Exception(pendExc)` özgün istisna adresini (RaiseAddr) kaybettirir.
- **Neden:** Kasıtlı (ana hata korunuyor); ama yutulan ikincil hata günlüklenebilir olmalı. **Şiddet: DÜŞÜK.**

### [R2-D-5] [BİLGİ] Commit edilmemiş sayfa katmanı yamaları (C-2/C-13/C-14/C-15/B-13/B-18/R-A-*) — doğruluk taraması
- `VDbPageEngine` B-18 (`FSyncBusy`/`FSyncEvt` finally içinde temizlenir, istisna yayılır): tutarlı.
- `VDbPageWal` C-14 (fsync hatasında tampon temizlenip yeniden-yazım önlenir, istisna yayılır): tutarlı; C-15 (`goodPos` kaydı) ve C-13 (`Bytes` şifreli yük hesabı): doğru yönde.
- `VDbPageHeap` R-A-3/R-A-4 (yarım zincir geri alma + adım sınırı `VDB_OVF_MAX_STEPS`): sonsuz döngü yerine güvenli çıkış; `WriteOverflow` geri alması en-iyi-çaba `except` ile maskeliyor ama `raise` ile asıl istisnayı koruyor — kabul edilebilir.
- `VDbBackendV3` C-2 (`.gen` durabil LSN sıfırlaması; başarısızlıkta açık hata): doğru; bayat "durabil" onayını önler.
- `VDbPageStore` R-A-11 (`FWriteCsInit`): doğru.
- Bu yamalarda yanlış-sorgu-sonucu üreten bir hata **bulunamadı**.

### Doğrulanan — sağlam bulunan commit edilmemiş noktalar
- **B-3 (`FLastDirtyIdx` kısayolu, `VDbTable.pas:7858-7865`):** `FIdxDirty`'nin TUM mutasyon noktaları tarandı (`Add`: `7863, 7908, 7933, 7958`; `Delete`: `8002, 9601, 9613`; `Clear`: `9426`). Her silme/temizlemede `FLastDirtyIdx := -1` var (`8003, 9427, 9602, 9614`); kurucuda `ResetBatchTableCache` (`5164`) `-1` yapar. **Sağlam.**
- **B-8 (RETURNING `retCi`/`retCiAll` önbelleği, `VDbExecutor.pas:15497-15509`):** `cnames`/`returningColNames`/`allColNames` döngü boyunca değişmiyor (`15455-15483` retCi hesabından önce sabitlenir; OR REPLACE kolu yalnız `OnConflictSetExprs` doldurur). Eski satır-bası doğrusal arama ile birebir eşdeğer. **Sağlam.**
- **B-11 hash hızlı yolu (`VDbTable.pas:7113-7121` + `VDbHashKeyBytes`, `1349-1412`):** `VDbIsPureAscii` (`1366-1377`) tüm baytlar <128 ise `UTF8Encode` kimliktir; `VDbHashKeyPrefix`+`VDbHashKeyBytes` FNV katlaması `VDbHashKey` ile birebir (`1379-1412`, `h=0→1` düzeltmesi katlamadan sonra). Boş/ASCII-dışı pk'da genel yol. **Hash eşitliği sağlam** — risk yalnız R2-D-1'deki bayrak kirletmesinde.
- **`HasIdxWork` kapısı (`7795-7810`, PutRow `7135-7137`):** Kapalıyken `IdxAddRow` no-op olurdu (T.Idx boş + FPkIdx yok). `FPkIdx` ekleme noktası önbelleği geçersiz kılıyor (`9805-9808`). **Sağlam.**
- **B-4 (`FOpenTDef` önbelleği):** İptal kapsamı tam — 27 `FTables` yazım noktasının tamamı `MarkSchema`'ya bağlı (ör. `9019-9020`, `10198-10200`); `LoadSchema` (`5660`), `ResetBatchTableCache` (`6391`) ve `MarkSchema` (`5996`) geçersiz kılıyor. Tek risk R2-D-1'in paylaştığı bayrak değişmezi.

### Genel eksende ek taramalar (yeni hata bulunamadı)
- **LIMIT/OFFSET uçları:** `LIMIT 0` tüm hızlı yollarda ele alınmış (`13281`, `13594`, `14025`, `14134`); genel yol OFFSET sonra LIMIT (`15228`, `15251-15253`, `15282-15283`); `LimitVal<0` (limitsiz) korumalı. Hızlı yollar `Stmt.LimitVal >= 0` vb. koşullarla devre dışı bırakılıyor (`4697`, `5471`, `5599`, `8904`, `9405`).
- **COUNT/MIN/MAX/boş grup semantiği ve `cnt=0`/`navg=0` korumaları:** yerinde (`VDbSql.pas:2317-2322, 2330, 2343, 2364`; `VDbExecutor.pas:8442`).
- **INSERT `Length(ColNames) <> Length(StrVals)` reddi:** `10524-10526`; `ApplyIdentity`/`VDbApplyGenerated`/`VDbIdxJoin` sınır kontrolleri korunuyor.

---

## Öneriler (öncelik sırasıyla)

1. **R2-D-1 (KRİTİK, commit edilmemiş):** `PutRow`'daki B-11 bloğunda `FPrefixCacheName` yazımını bayrak taramasıyla atomik yap (`FBatchHasIdentity/FBatchHasGenerated`'ı yeniden hesapla) ya da bayrak geçerliliğini ayrı bir `FBatchFlagsName` jetonuna bağla. Bu yama commit edilmeden önce düzeltilmelidir.
2. **D-1a + R2-D-2 (KRİTİK/YÜKSEK):** Her şema değişikliğinde (ALTER/CREATE/DROP TABLE/INDEX/RewriteTable) `ResetBatchTableCache` çağır — `MarkSchema` gövdesine tek satır eklemek en dar çözümdür.
3. **D-Y1/D-Y2 (YÜKSEK):** `AggOf` ve pencere SUM/AVG'de integer biriktirmeyi `Int64`'e al, float girişte `Double` kullan; `2^53` kararıyla (`VDbTable.pas:1980-1986` yorumu) tutarlı ol.
4. **R2-D-3 / D-Y3 (ORTA):** FK kaskad commit/abort simetrisini `FT.BeginBatch/CommitBatch/AbortBatch` düzeyine taşı; `try AbortBatch except end` yutma noktalarına (`VDbExecutor.pas:17117`, `VDbSql.pas:3271`) iz günlüğü ekle.
5. **D-Y5 (DÜŞÜK):** Tarih `TryStrToDate` locale-fallback'ini kaldır; yalnız `yyyy-mm-dd` kabul et.
---

# EK-E — alt ajan tam raporu

# VDb v3 — Performans Denetimi R2 (INSERT/UPDATE Yolu) — Eski İddiaların Doğrulaması + Yeni Denetim

- **Tarih:** 2026-11-06
- **HEAD:** `d6f6f61` ("P-125: denetim bulgularindan guvenli duzeltmeler") — denetim başlangıcında `1fe0acf` idi; inceleme sırasında eşzamanlı bir oturum `d6f6f61`'i commit etti ve yeni bir dalga başlattı.
- **ÇALIŞMA AĞACİ KİRLİ:** `VDbBackendV3.pas`, `VDbExecutor.pas`, `VDbSql.pas` commit edilmemiş değişiklik içeriyor (B7/B9/B10 uygulanıyor). `VDbPageEngine/VDbPageHeap/VDbPageStore/VDbPageWal/VDbTable` değişiklikleri `d6f6f61`'e commit edildi. Bu rapor **ağaç d6f6f61 + 3 kirli dosya** durumuna göredir; ağaç inceleme sırasında canlı değişti, satır numaraları yazım anındaki durumu yansıtır.
- **Kapsam:** Salt okunur inceleme. Hiçbir dosya değiştirilmedi, derleme/ölçüm YAPILMADI. Tüm kazançlar **"tahmin"** etiketlidir.
- **Ölçüm tabanı (değişmedi):** tablo API 6,39 µs/satır @1M (SQLite 3,12); SQL text batch 12,22 µs/satır; nokta okuma 2,90 µs; tam tarama 75-86 ns/satır; autocommit 0,38 ms/commit.

---

## Yönetici özeti — Kısım 1'in kaderi

`d6f6f61` commit'i + mevcut kirli dalga, 14 bulgunun **5'ini tamamen**, **5'ini kısmen** uygulamış. Kalan 4 madde (B1, B2, B5, B6, B12 — en büyük satır-içi kalemler) dokunulmamış durumda; 6,39 → 3,12 µs/satır boşluğunun büyük bölümünü taşıyan **B1 (çift sondalama) hâlâ yerinde**.

| # | Eski bulgu | Kader | Güncel kanıt (dosya:satır) | Kazanç tahmini (tahmin) |
|---|-----------|-------|-----------------------------|--------------------------|
| B1 | PK varlık denetimi çift sondalama | **HALA GEÇERLİ** | VDbTable.pas:10642-10649 (Exists+Get); VDbBackendV3.pas:2218-2258 (Exists: 2230 Map, 2234 FEngCs, 2242 FSets, 2254 FEng.Contains), 1938 (FEng.Insert ikinci sondalama) | 0,8–1,8 µs/satır (tahmin) — değişmedi |
| B2 | Oto-PK/IDENTITY satır başına ReadRow | **HALA GEÇERLİ** | VDbTable.pas:10606-10615 (ReadRow 10610), ApplyIdentity 6098-6104 (ReadRow 6101), MaxPkInt 7345 | 0,5–1,5 µs/satır oto-PK (tahmin) |
| B3 | IdxAddRow sözlük/IndexOf/dizi trafiği | **KISMEN UYGULANDI** (d6f6f61) | Uygulanan: FLastDirtyIdx önbelleği 7858-7865. **Kalan:** FPkIdx/FPkIdxDirty 7825-7826; FIdxCtype.AddOrSetValue 7847-7849, 7902-7904; VDbIdxJoin(Incl) 7843; IdxKeyOfRow→IdxColsOf tahsisi 7382-7398; IdxDelRow/IdxAdd/IdxDel'de çıplak IndexOf 7908, 7933, 7958; VDbIdxJoin birleştirme 2633 | Kalan için 0,2–1,0 µs/satır indeksli (tahmin); ayrıca bkz. R2-E-4 |
| B4 | Batch-dışı Insert satır başına GetTable sema kopyası | **UYGULANDI** (d6f6f61) | FOpenTDef tek-girdili önbellek: VDbTable.pas:10492-10517; geçersizleştirme 5663, 5996, 6391 | 0,2–0,6 µs/satır (tahmin) korunur; artık yalnız önbellek ıskalarında GetTable. Yeni ikincil maliyet: R2-E-5. Yeni tutarlılık tuzağı: R2-E-3 |
| B5 | CheckConstraints kolon/indeks turu | **HALA GEÇERLİ** | VDbTable.pas:6506-6580 (NULL denetimi 6518, parti kolon dizesi 6536); UNIQUE indeks turu 6587-6669 (icols tahsisi + VDbIdxJoin 6625-6626) | 0,2–0,8 µs/satır (tahmin) |
| B6 | CheckFk FindCol + VDbNorm | **HALA GEÇERLİ** | VDbTable.pas:7072-7086 (VDbNorm 7076, FindCol 7080); RefValueExists ReadRow 6683 | 0,1–0,4 µs/satır/FK (tahmin) |
| B7 | SplitStatements karakter birleştirme + O(n²) | **UYGULANDI** (kirli ağaç, commit edilmedi) | VDbSql.pas:3017-3028 (indeks aralığıyla tek Copy + CompareText), 3056/3071 (tek Trim(Copy)), 3061/3076 (katlanan kapasite), 3082 (SetLength(Result,cnt)) | 1–3 µs/cümle çok-cümleli metinde (tahmin) — artık gerçek |
| B8 | RETURNING O(kolon²) + O(n²) dizi | **KISMEN UYGULANDI** (d6f6f61) | Uygulanan: retCi/retCiAll eşleme 15500-15511. **Kalan:** `SetLength(returningRows, Length+1)` O(n²) 13 noktada: VDbExecutor.pas:15612, 15653, 15692, 15721, 15760, 15807, 15839, 15866, 15904, 15948, 18065, 18126, 18328 | Eşleme kalktı (~0,5–1 µs/satır, tahmin); dizi büyümesi kalan: 0,2–1 µs/satır RETURNING'li (tahmin) |
| B9 | Satır başına tetikleyici/RLS yoklaması | **KISMEN UYGULANDI** (kirli ağaç) | Cümle başına ön-kontrol: VDbExecutor.pas:15574-15583 (INSERT), 17108 (bulk/COPY); satır çağrıları `hasInsTrig`/`needRls` ile kapalı. **Kalan:** FireTriggers gövdesinde kullanılmayan sema kopyası 19412 (bkz. R2-E-1); tetikleyici VARSA satır başına çağrı sürüyor (muhafazakâr) | Tetikleyicisiz tabloda 0,3–1 µs/satır genel yol (tahmin) — artık kapanıyor |
| B10 | Plan önbelleği AST sızıntısı | **UYGULANDI** (kirli ağaç) | VDbSql.pas: FreePlanCache 361-368 (tek sahiplik noktası), destructor 277, ClearPlanCache 373, StmtMutated Remove+Free ~4288-4295, cap aşımı 4345, DDL temizliği 4361 | Dolaylı (uzun süreli bellek baskısı önlenir, tahmin) |
| B11 | PutRow tam okuma + deşifre + hash | **KISMEN UYGULANDI** (d6f6f61) | Uygulanan: P-56 prefix önbelleği 7111-7122, HasIdxWork kapısı 7140. **Kalan:** çarpışma sınıflandırması için tam okuma+DecodeRow 7123-7131; `b := EncodeRow(...)` TBytes tahsisi 7132 (FEncBuf/PutPtr deseni yok) | Kalan için 0,3–1,0 µs/satır UPDATE/PUT (tahmin) |
| B12 | Partial indeks predicate yeniden ayrıştırma | **HALA GEÇERLİ** | VDbTable.pas:7831, 7887 (VDbPredOK satır başına); VDbPredOK 2082+ metin yorumlayıcı, `SVal := SVal + S[P]` 2144, 2165 | 0,5+ µs/satır partial indeksli (tahmin) |
| B13 | PutPtr çift denetim + ValBuf birikimi | **KISMEN UYGULANDI** (d6f6f61) | Çift denetim kalktı: VDbBackendV3.pas:1889-1891. **Kalan:** overwrite'te ValBuf birikimi 1895-1920 (s.ValLen yalnız artar) | Küçük çağrı tasarrufu alındı; kalan = bellek (overwrite-ezici batch'lerde), tahmin |
| B14 | Autocommit/fsync sınırı | **GEÇERLİ, DEĞİŞMEDİ** (öneri düzeyinde) | VDbPageEngine.pas:873-875 (grup commit, fsync 0,32 ms); VDbBackendV3.pas:3016+ (WAL yaz fsync'siz), 3120-3137 (P-61/P-DUR v2, ~360 µs/fsync), 533-536 (DurableOnFlush) | fsync dışı kalan <0,1 ms/commit (tahmin); asıl kazanç uygulama davranışında (batch) |

**Değerlendirme:** Uygulanan maddeler (B4, B7, B9, B10 + kısmen B3/B8/B11/B13) SQL metin katmanı (12,22 µs/satır) ve indeksli yükte ölçülebilir iyileşme getirmelidir (tahmin). Ancak tablo API'deki 6,39 → 3,12 boşluğunu belirleyen **B1 + B2 + B3 kalıntıları** hâlâ açıktır; sıralama değişmemiştir.

---

## Kısım 2 — Yeni bulgular (R2-E-…)

### R2-E-1 — FireTriggers'ta kullanılmayan tam sema kopyası (ölü kod) — EN UCUZ KAZANÇ

**Kanıt:** `VDbExecutor.pas:19412` — `tds := FT.GetTable(TableName);` ataması fonksiyon gövdesinde (19413-19438) **hiçbir yerde kullanılmıyor**; her FireTriggers çağrısında tam TTableDef kayıt kopyası (Cols/Idx/Fks/Checks dinamik dizilerinde refcount trafiği) boşa yapılıyor. FireTriggers satır başına 2 kez (BEFORE/AFTER) çağrıldığında bu satır başına 2 ölü kopyadır.

**Öneri:** `tds` satırını sil; ayrıca `names := FT.TriggersFor(...)` sonucu tablo+timing+event için cümle/atama düzeyinde önbelleklenebilir (bkz. B9).

**Tahmini kazanç:** 0,1–0,4 µs/satır genel INSERT yolu (tahmin); sıfır davranış riski (kodu okuyan herkes için bedava).
**Risk:** Çok düşük.

### R2-E-2 — FT.BeginBatch dönüşümü: otomatik işlem başına sema yedeği + önbellek geçersizleştirme maliyeti (YENİ eklenen doğrulama maliyeti)

**Kanıt:** `d6f6f61`, yürütücüdeki örtük batch sarmalarını `FT.Backend.BeginBatch/CommitBatch` → `FT.BeginBatch/CommitBatch` yaptı (VDbExecutor.pas:15669/15814, 16255/16264, 17114/17152, 18021/18074, 18265/18280). TVTableDb sarmalayıcısı şunları yapar:
- `TVTableDb.BeginBatch` (VDbTable.pas:6395-6404) → `SnapshotSchema` (6126-6152: **3 sözlük alloc + tüm tabloların TTableDef kopyaları + FlushAutoIncCache**) + `ClearSavepoints` + `ResetBatchTableCache` (6376-6393: B-4/P-56/P-63/B-3 önbelleklerinin tamamını siler).
- `TVTableDb.CommitBatch` (6406-6419) → `FlushAutoIncCache` + `ResetBatchTableCache` + FSchemaDirty ise `SaveSchema` + `ClearSavepoints` + `ClearSchemaSnapshot` (3 sözlük free).

**Etki:** Çok satırlı VALUES / fast-literal / UPDATE / DELETE statement'ları artık her otomatik işlemde sema yedeği alıyor. Bu bir **doğruluk kazancı** (DDL+ROLLBACK geri alınır, P-31 sayaç onbellegi yazdırılır — bkz. 19105'teki uyarı yorumu), ama maliyeti statement başına sabittir: 3 sözlük + O(#tablo) kayıt kopyası + refcount trafiği. Büyük semalarda (yüzlerce tablo) belirgin; ayrıca `ResetBatchTableCache` yeni B-4 önbelleğinin ömrünü statement sınırında kesiyor.

**Öneri:** (a) `SnapshotSchema`'yı tembelleştir — yalnız DDL dokunduğunda gerçekten kopyala (dirty bayrağı + ilk DDL'de anlık yedek). (b) `ResetBatchTableCache`'i sema kirliliği yoksa önbellekleri koruyacak biçimde daralt (FOpenTDef/P-56 geçerliliğini yalnız MarkSchema bozsun). (c) Mevcut `VDbSql.ExecAllInner` davranışı (tüm metin tek batch, 3256) doğru kalıp; statement-içi sarmalar yalnız `not InBatch` iken çalışıyor — bu iyi.

**Tahmini kazanç (maliyet önleme):** 2–10 µs/statement, semaya bağlı (tahmin); satır sayısına bölününce çok satırlıda küçük, tek satırlı VALUES statement'larında doğrudan görünür.
**Risk:** Orta — geri alma sözleşmesi (RestoreSchemaSnapshot) korunmalı; yalnız yedek ALMA maliyeti ertelenmeli, yedekleme semantiği değil.

### R2-E-3 — PutRow'un FPrefixCacheName yazması P-67 bayrak önbelleğini bayatlatabilir (YENİ tutarlılık TUZAĞI — doğruluk riski)

**Kanıt:**
- `VDbTable.pas:7114-7118` (B-11 düzeltmesi, d6f6f61): PutRow `FPrefixCacheName`'i yazar ama `FBatchHasIdentity`/`FBatchHasGenerated`'ü **hesaplamaz**.
- `VDbTable.pas:10440-10452` (Insert, ATableDef dalı): P-67 bayrakları yalnız `FPrefixCacheName <> tp^.Name` iken yeniden hesaplanır.
- Senaryo: herhangi bir `ResetBatchTableCache` sonrası (6391: FPrefixCacheName := '', bayraklar False) → `PutRow('t')` (7116: FPrefixCacheName := 't') → batch-dışı `Insert('t', …, @td)` → ad eşleştiği için bayrak taraması **ATLANIR** → `if FBatchHasIdentity then ApplyIdentity` (10583-10584) çalışmaz → IDENTITY kolonu boş kalır.
- Müdüniyet: bu delik B-11 öncesi yoktu; PutRow tek başına FPrefixCacheName yazan ilk yer.

**Öneri:** PutRow kendi prefix alanlarını kullansın (ayrı `FPutPrefixName/Val`) veya bayrakları da tazelesin; alternatif: Insert'te bayrak taramasını ad-eşleşmesine değil `FBatchFlagsTid` (TableId) bayrağına bağla.

**Tahmini kazanç:** performans değil, doğruluk; senaryo dar (batch-dışı ATableDef'li Insert + öncesinde PutRow) ama sessiz veri hatası üretir.
**Risk:** Düşük-orta (düzeltme küçük; test: IDENTITY'li tabloya PutRow sonrası ATableDef'li Insert).

### R2-E-4 — FLastDirtyIdx önbelleği çok indeksli tabloda etkisiz + asimetrik (B3 kalıntısına yeni ayrıntı)

**Kanıt:**
- `VDbTable.pas:7861-7865` (IdxAddRow): önbellek yalnız "son işlenen indeks anahtarı"nı hatırlar. 2+ indeksli tabloda IdxAddRow döngüsü (7827-7866) her satırda sırayla farklı k'ye geçtiği için `FLastDirtyIdx <> k` her seferinde doğrudur → tam `FIdxDirty.IndexOf` (O(kirli liste)) satır başına indeks başına aynen sürer. Önbellek yalnız **tek indeksli** tabloda iş görür.
- Asimetri: `IdxDelRow` 7908, `IdxAdd` 7933, `IdxDel` 7958 önbelleği hiç kullanmaz. Silme noktalarında sıfırlama disiplini doğru (8003, 9427, 9602, 9614) — doğruluk tamam.
- İkincil risk: gelecekte FIdxDirty'den eleman silen yeni bir nokta `FLastDirtyIdx := -1`'i unutursa, o indeks "zaten kirli" sanılır ve **eklenmez → indeks flush'u satırı atlar → sessiz indeks bozulması**. Yorum satırı (7858-7860) uyarıyor ama yapısal garanti yok.

**Öneri:** `TList<Int64>` yerine (veya yanında) `TDictionary<Int64,Byte>` kümesi; veya FIdxDirty'yi saran tek bir AddDirty(k) / RemoveDirty(k) yardımcı fonksiyonu (tüm mutasyon noktaları oradan geçsin).

**Tahmini kazanç:** çok indeksli tabloda 0,1–0,5 µs/satır (tahmin); tek indekslide ~0 (önbellek zaten çalışıyor).
**Risk:** Düşük.

### R2-E-5 — B-4 önbellek kontrolünde satır başına VDbNorm taraması (mikro)

**Kanıt:** `VDbTable.pas:10496` — `FOpenTDef.Name <> VDbNorm(Table)`. `VDbNorm` (1322-1347) küçük-harfli ASCII adlarda tahsis etmez ama her satırda adı tarar (O(ad)); **büyük harfli/sekmeli tablo adlarında her satırda `LowerCase(Trim(S))` tahsis eder**.

**Öneri:** Ham `Table` adını da önbelleğe al (`FOpenTDefRawName <> Table`), VDbNorm'u yalnız isabet etmediğinde çağır.

**Tahmini kazanç:** 0,05–0,2 µs/satır, büyük-harfli adlarda daha yüksek (tahmin).
**Risk:** Çok düşük.

### R2-E-6 — INSERT ... SELECT yolunda batch sarmalama YOK: satır başına otomatik-commit yazımı

**Kanıt:**
- `VDbExecutor.pas:15586-15615` (INSERT...SELECT, ON CONFLICT'siz) ve 15640-15670 (upsert'lu) satır döngüleri **batch sarmasız**; her satır `FT.Insert(..., @td)` veya `FT.UpsertRowReturning` ile tek tek yazılır. Karşılaştırma: çok satırlı VALUES aynı statement'ta `FT.BeginBatch` alıyor (15667-15669).
- Batch dışındaki her yazım `TVdbBackendV3.PutPtr` otomatik-commit yoluna düşer: `VDbBackendV3.pas:1930-1948` — satır başına `FEng.Store.AcquireWrite` (tam kilit) + `FEngCs.Enter` + `FEng.Insert` + `LogPut` + `TagAdd`.
- Bu döngüde satır başına ayrıca 2× FireTriggers (R2-E-1/B9 ile kısmen kapandı) + RETURNING O(n²) dizi (B8 kalıntısı) de var.

**Öneri:** INSERT...SELECT satır döngüsünü de `if not FT.Backend.InBatch then FT.BeginBatch` ile sarmala (VALUES 15667-15669 deseniyle birebir aynı; `bi=1` muhafaza bayrağı ile, 16255-16264'teki gibi).

**Tahmini kazanç:** 1–3 µs/satır büyük SELECT→INSERT kopyalarında (tahmin; otomatik-commit kilit/fsync amortisyonuna bağlı); ayrıca tek batch'te tek commit ile 0,38 ms'lik commit maliyeti tek sefer iner.
**Risk:** Düşük-orta — satır hatasında tüm batch geri alınır (tek tek yazımın aksine); mevcut VALUES davranışıyla eşitlenirse tutarlı.

### R2-E-7 — `INSERT () VALUES ()` + RETURNING dalında AFTER tetikleyici ÇİFTE ateşleniyor (yeni keşif; hem doğruluk hem maliyet)

**Kanıt:** `VDbExecutor.pas:15684-15685` — AFTER ROW tetikleyici `FT.Insert` sonrası çağrılıyor; sonra `if hasReturning then` bloğu içinde **aynı çağrı tekrar** (15694-15695). Bu dal (`ValuesRows[i].Count = 0`, ocaNone, RETURNING'li) satır başına AFTER tetikleyiciyi iki kez çalıştırır. Yeni B9 sarması (`if hasInsTrig then`) çağrıyı kapattı ama **çift yapıyı korudu**.

**Öneri:** 15694-15695'teki ikinci çağıyı sil (veya 15684-15685'teki birincili) — F-36 sözleşmesi (satır başına tek BEFORE + tek AFTER) ile karşılaştırıp test et.

**Tahmini kazanç:** tetikleyici varsa 0,5–2 µs/satır bu dalda (tahmin); asıl değer doğruluk (tetikleyici yan etkileri iki kez çalışır).
**Risk:** Düşük (davranış değişir — kasıtlı mı kontrol edilmeli; diğer dallar tek çağrı kullanıyor, dolayısıyla kaza olduğu güçlü).

### R2-E-8 — LogPut'ta nesne-ömrü tampon yeniden kullanımı (yeni mikro-iyileştirme, inceleme notu)

**Kanıt:** `VDbBackendV3.pas:297, 951-954` (kirli ağaç) — değişim günlüğü açıkken satır başına `TBytes` tahsisi yerine `FLogNewBuf` yeniden kullanılıyor; yalnız boyut değişince SetLength. Yorumda `AddPut`'ın değeri anında kopyaladığı varsayımı kanıt gösterilmiş — bu varsayım değişirse sessiz veri bozulması olur; `TVdbChangeLog.AddPut` sözleşmesine birim test eklenmeli (tahmin: ~0,1–0,3 µs/satır yalnız günlük-açık iş yükünde).

### R2-E-9 — Tasma zinciri denetimlerinin mutlu-yol maliyeti ihmal edilebilir (d6f6f61, inceleme notu)

**Kanıt:** `VDbPageHeap.pas:535-548` (ReadOverflow adım sayacı), 596-608 (FreeOverflow), 455-510 (WriteOverflow try/except geri alma). Mutlu yol: chunk başına ~1 artırma + 1 karşılaştırma + try iskeleti → **<10 ns/tasma-sayfası (tahmin)**; INSERT benchmarkında (VDB_MAX_INLINE=1000 üstü değerler) bile görünmez. Küçük kalan fırsat: WriteOverflow'ta chunk başına `SetLength(cell, 4+chunk)` tahsisi sürüyor (~466-470) — tek seferlik hücre tamponu ile kalkar (tahmin: önemsiz-orta).

### R2-E-10 — CommitBatch C-6 istisna sarmalayıcısı: mutlu yol maliyeti yok; ama `pendExc` kalıbı belgeyi hak ediyor (inceleme notu)

`VDbBackendV3.pas:3000-3075` (d6f6f61): try/except + `AcquireExceptionObject` + `raise Exception(pendExc)` yalnız hata yolunda çalışır; mutlu yol maliyeti ihmal edilebilir (tahmin). Değerlendirme: doğru takas (durabilite garantisi > istisna iskeleti). Not: `raise Exception(pendExc)` kalıbı FPC'de nesne ömrünü doğru aktarır; kodda bir yorumla işaretlenmiş, iyi.

---

## Öncelik sırası (beklenen etkiye göre, tahmin)

1. **B1** (varlık denetimini yazmayla birleştir) — hâlâ en büyük ölçülebilir kalem (0,8–1,8 µs/satır).
2. **R2-E-6** (INSERT...SELECT'e batch) — yeni, büyük, düşük riskli (1–3 µs/satır o yolda).
3. **B2 + B3 kalıntıları** (oto-PK ReadRow; FIdxCtype/IdxColsOf tahsisleri) — indeksli/oto-PK yükte.
4. **R2-E-2** (tembel sema yedeği) — statement başına sabit maliyet; büyük semalarda değerli.
5. **R2-E-1 + B8 kalıntısı** (ölü kopya; returningRows kapasitesi) — bedava/ucuz temizlik.
6. **R2-E-3** (doğruluk tuzağı) — performanstan bağımsız, küçük ama öncelikli düzeltilmeli.

## Doğrulama önerisi (bu inceleme dışında)

Uygulanan her madde için mevcut benchmarkların (tb.Insert 1M; SQL text batch; multi-row VALUES; UPDATE) A/B ölçümü alınmalıdır — buradaki tüm rakamlar **tahmin**tir. Ek testler: (a) R2-E-3 senaryosu (PutRow → ATableDef'li Insert, IDENTITY'li tablo); (b) R2-E-7 çift AFTER tetikleyici davranışı; (c) B10 için plan önbelleği cap aşımında bellek sızıntısı kalmadığının doğrulanması (FreePlanCache); (d) B7 SplitStatements için BEGIN/END blok, tırnak ve yorum durumları regresyon paketi.
---

# EK-F — alt ajan tam raporu

# DENETİM RAPORU R2 — Mimari / API / Kod Kalitesi / Test Boşlukları (F ekseni, 2. tur)

**Hedef:** `D:\veritabani` · dal `v3` · **HEAD `1fe0acf`** (06.11.2026 01:53, "docs: derinlemesine kod inceleme raporu" — yalnız `DERINLEMESINE_INCELEME.md` +1411 satır)
**ÇALIŞMA AĞACI KİRLİ:** 7 dosyada commit edilmemiş çalışma var — `VDbBackendV3.pas`, `VDbExecutor.pas`, `VDbPageEngine.pas`, `VDbPageHeap.pas`, `VDbPageStore.pas`, `VDbPageWal.pas`, `VDbTable.pas` (+297/−87). Tüm satır numaraları bu **güncel çalışma ağacı** görseline göredir.
**Tarih:** 2026-11-06 · **Mod:** salt okunur (hiçbir dosya değiştirilmedi, derleme/çalıştırma yapılmadı)
**Kapsam:** (KISIM 1) `tmp64/r_F.md` raporundaki 20 iddianın tek tek doğrulanması; (KISIM 2) aynı eksende yeni denetim + commit edilmemiş değişikliklerin test kapsamı haritası.

---

## 0. YÖNTEM

- Her iddia güncel dosyada `grep`/`read` ile tekrar arandı; yalnız tanım/uygulama satırı bulunan "ölü API" iddiaları için **tüm ağaç** (`.pas`, `.lpr`, `.sh`, `.yml`, `.md`) tarandı.
- Commit edilmemiş değişikliklerin **diff'leri** tek tek okunup yorum/niyet ile kod karşılaştırıldı.
- Derleme/çalıştırma YAPILMADI; test kapsamı yalnız `uses` listeleri + test gövdelerindeki isim/davranış taramasıyla çıkarıldı. Doğrulanamayan davranışsal iddialar `ŞÜPHELİ` işaretlidir.

---

## KISIM 1 — ESKİ 20 İDDİANIN KADERİ

**Özet:** 20 iddianın **19'u GEÇERLİ, 1'i KISMEN** (F-BİLGİ-1 kalan riski kısmen kapandı ama yeni bir KRİTİK boşlukla). Hiçbiri DÜZELTİLMİŞ veya GEÇERSİZ değil; commit edilmemiş çalışma bu listenin hiçbir maddesine dokunmamıştır.

| # | Eski etiket | Karar | Güncel kanıt |
|---|---|---|---|
| 1 | F-Y1a: 7 istisna sınıfı / 3 şema | **GEÇERLİ (genişledi)** | 17 farklı istisna sınıfı + ham `Exception` (aşağıda) |
| 2 | F-Y1b: PgWire SQLSTATE kırığı | **GEÇERLİ** | `VDbPgWire.pas:647-648` değişmedi |
| 3 | F-Y1c: savepoint aynı koşul/iki istisna | **GEÇERLİ** | `VDbBackendV3.pas:3273` vs `VDbTable.pas:6306-6307` |
| 4 | F-Y2: doğrulama borcu | **GEÇERLİ** | HEAD `1fe0acf` de test kaydı içermiyor; 7 dosyalık çalışma sınanmamış |
| 5 | F-Y3: `StoreGenStamp` ölü API | **GEÇERLİ** | çağıran hâlâ YOK |
| 6 | F-Y4a: `BeginWrite/EndWrite` erişilemez | **GEÇERLİ** | çağıran hâlâ YOK |
| 7 | F-Y4b: `ExclusiveAccess` erişilemez | **GEÇERLİ** | `True` yapan hâlâ YOK |
| 8 | F-ORTA-1: test boşlukları | **GEÇERLİ** | adı geçen yolların hiçbir testte izi yok |
| 9 | F-ORTA-2: runall↔ci.yml tutarsızlığı | **GEÇERLİ** | 3 fark da duruyor |
| 10 | F-ORTA-3: VDbFactory tutarsızlıkları | **GEÇERLİ** | imzalar değişmedi |
| 11 | F-ORTA-4: VDbTable→v2 çekirdek bağı | **GEÇERLİ** | `VDbTable.pas:14-17`, `:5100-5104` |
| 12 | F-ORTA-5: IVDbBackend sonuç sözleşmeleri | **GEÇERLİ** | dosya değişmedi |
| 13 | F-ORTA-6: VDbExecutor uses şişkinliği | **GEÇERLİ** | `VDbExecutor.pas:25-29`, `VDbSql.pas:24` |
| 14 | F-DÜŞÜK-1: sihirli sayılar | **GEÇERLİ** | 4096/16 öbekleri yerinde |
| 15 | F-DÜŞÜK-2: kod tekrarı | **GEÇERLİ** | P-67 döngüsü hâlâ 3 kopya |
| 16 | F-DÜŞÜK-3: mojibake | **GEÇERLİ** | 50+ bozuk yorum sürdü |
| 17 | F-DÜŞÜK-4: derleme artefaktları | **GEÇERLİ** | `.s/.exe/.o/.ppu/.backup` diskte |
| 18 | F-BİLGİ-1: P-67 çürütmesi + kalan risk | **KISMEN** | bayraklar okunuyor (çürütme doğru); kalan riskin non-batch dalı B-4 ile kapandı, batch dalı (D-1a) KRİTİK olarak açık |
| 19 | F-BİLGİ-2a: yorum/sınıf eşleşmesi bozuk | **GEÇERLİ** | `VDbBackendApi.pas:339-342` |
| 20 | F-BİLGİ-2b: isimlendirme / arayüzde varsayılan parametre | **GEÇERLİ** | `VDbBackendApi.pas:37/57/72/344`, `:65-66` vs `:87-88` |

### Detay (güncel satır kanıtları)

**1 — F-Y1a [YÜKSEK] GEÇERLİ, kapsam raporlanandan geniş.** `VDbErr.pas:8-11` kuralı ("yalnızca `Exception` → `EVDbException` olur ve kod eklenir") hâlâ yürürlükte ve hâlâ çiğneniyor. Güncel ağaçta **17 ayrı istisna sınıfı**: kodlu tek sınıf `EVDbException` (`VDbErr.pas:73-79`); kodsuz `EVdbBackendV3` (`VDbBackendV3.pas:43`), `EVdbBackendV2` (`VDbBackendV2.pas:21`), `EVdbFactory` (`VDbFactory.pas:41`), `EVdbBackendApi` (`VDbBackendApi.pas:342`), `EVdbChangeLog` (`VDbChangeLog.pas:67`), `EVdbHeap` (`VDbPageHeap.pas:58`), `EVdbPageEngine` (`VDbPageEngine.pas:33`), `EVdbPageStore` (`VDbPageStore.pas:78`), `EVdbPageWal` (`VDbPageWal.pas:59`), `EVdbPageCrypto` (`VDbPageCrypto.pas:38`), `EVdbIdxFile` (`VDbIdxFile.pas:54`), `EVdbKdfError` (`VDbKdf.pas:20`), `EVdbTlsError` (`VDbTls.pas:21`), `EVdbClientError`+`EVdbProtocolError` (`VDbClientNet.pas:28-29`), `EVDbApiError` (`VDbClient.pas:75`); kendi kodlu `EVdbCryptError` (`VDbCrypt.pas:42`). Ham `Exception` raise'leri sürüyor: `VDbArrow.pas:864-1394` (38+), ayrıca `VDbParquet`, `VDbClient`, `VDbMigrate`. Eski rapor 7 sınıf saymıştı; gerçek envanter 2,5 katı.

**2 — F-Y1b [YÜKSEK] GEÇERLİ.** `VDbPgWire.pas:647-648` SQLSTATE eşlemesi (`ecDuplicateSavepoint → '3B001'`, `ecSavepointNotFound → '3B000'`) yalnız kodlu `EVDbException`'da çalışır. v3 backend'i kodsuz fırlattığı için protokol istemcisi genel hata alır — mekanizma olduğu gibi duruyor.

**3 — F-Y1c [YÜKSEK] GEÇERLİ.** Aynı koşul iki farklı istisna: `VDbTable.pas:6306-6307` → `EVDbException.CreateFmt(ecDuplicateSavepoint, ...)`; `VDbBackendV3.pas:3273` → `EVdbBackendV3.CreateFmt('savepoint zaten var: %s', ...)` (kodsuz). Arayüz sözü açıkça `EVDbException ecDuplicateSavepoint` vaat ediyor: `VDbBackendApi.pas:148-150`.

**4 — F-Y2 [YÜKSEK] GEÇERLİ.** HEAD `1fe0acf` tek dosyalık docs commit'i; mesajında `Doğrulama:` satırı yok. Commit edilmemiş 7 dosyalık değişiklik için de hiçbir test kaydı yok (çalışma ağacı kirli, kanıt yok). Derleme izleri güncel ağacı kapsamıyor: `tests/gates/*.exe` = 02.11 07:26, `tests/sql/sqltest.exe` = 05.11 11:00; bunlardan sonra değişen kaynaklar: 7 çalışma ağacı dosyası (06.11), `VDbCore`, `VDbMM`, `VDbSql` vb. (05.11). (ŞÜPHELİ bileşen: kapılar `runall.sh` ile `$WORK/bin` dizinine derlendiğinden yan `.exe` tarihleri yalnız destekleyici kanıttır.)

**5 — F-Y3 [YÜKSEK] GEÇERLİ.** `StoreGenStamp` sözleşme: `VDbBackendApi.pas:138-142`; uygulama: `VDbBackendV3.pas:577, 3174-3177` (→ `VDbPageStore.GenStamp`, `VDbPageStore.pas:375, 1140`), `VDbBackendV2.pas:68, 314`. **Tüm ağaçta çağıran yok** (tests dahil). v3.31'te `.gen` offset-8'e durabil LSN alanı eklenmiş (`VDbPageStore.pas:296, 377`) ama "çok süreçli DDL tazelik" hâlâ `StoreGenStamp`'e bağlı değil; `VDbTable.ReloadSchema` (`VDbTable.pas:6366`) yalnız sunucu tarafı tetiklerle çağrılıyor.

**6 — F-Y4a [YÜKSEK] GEÇERLİ.** `IVDbBackend.BeginWrite/EndWrite` (`VDbBackendApi.pas:125-131`) hâlâ hiçbir yerden çağrılmıyor; tek "benzer" kullanım `VDbTable.pas:5213/5219` `FLock.BeginWrite/EndWrite` — o bir TMREW (VDbSync) nesnesi. Tanım/uygulama: `VDbBackendV2.pas:293/298`, `VDbBackendV3.pas:572-573, 3159/3164`. Ek kanıt: `VDbExecutor.pas:19083`'teki resmi kural ("`FT.BeginBatch` kullanılır, `FT.Kv.BeginBatch` DEĞİL") bu API'nin hiç bağlanmadığını ima ediyor. Ölü API + uygulanmamış optimizasyon.

**7 — F-Y4b [YÜKSEK] GEÇERLİ.** `ExclusiveAccess`'i `True` yapan hiçbir kod yolu yok (tek yazım `VDbBackendV3.pas:3463-3465` uygulaması). Okurlar: `VDbTable.pas:5210-5230` (MREW atlar), `VDbPageStore.pas:1292, 1494, 1555, 1589, 1619` (dosya kilitlerini atlar). Ek risk: `DERINLEMESINE_INCELEME.md` B-17 — çalışma anında değiştirilirse MREW Lock/Unlock çifti bozulabilir; `FExclusiveAccess` barrier'sız okunur. API yüzeyi hâlâ açık, hâlâ testsiz.

**8 — F-ORTA-1 [ORTA] GEÇERLİ.** `tests/` ağacında `ExclusiveAccess`, `StoreGenStamp`, `DurableOnFlush`, `VDB_WAL_VER`, `WaitForeignTxn`, `RefreshBatchSnapshot`, `BeginWrite` isimlerinin **hiçbiri geçmiyor** (sqltest'teki `WalCrc` bir yerel değişken adıdır, `VDbPageWal.WalCrc` değil). `VDbMM` yalnız `tests/bench/` içinde (`bdiag.lpr:7`, `joindiag.lpr:10`, `p110prof/*`, `probe.lpr:7`) — kapı değil. `VDbExecutor` hâlâ yalnız `sqltest` üzerinden sınanıyor (hiçbir kapı `uses` etmiyor).

**9 — F-ORTA-2 [ORTA] GEÇERLİ.** `runall.sh:12-13` "aynı tablo" iddiası hâlâ yanlış: (a) `runall.sh:132` sqltest'i yalnız `--backend=v3` koşuyor; `ci.yml:392-405` (v2) + `ci.yml:407-431` (v3) iki koşum — Linux/macOS job'ları (`ci.yml:559-561, 581-583`) v2 SQL paketini hiç koşmuyor; (b) `vdbmig` kapısı yalnız `ci.yml:212-247`'de; (c) `ci.yml:428-429` yalnız `atlanan=` raporlanıyor mu diye bakıyor, sıfır mı değil; `runall.sh:98-104` yalnız `kalan=0` denetliyor → yeni atlanan testler sessizce geçer.

**10 — F-ORTA-3 [ORTA] GEÇERLİ.** `VDbFactory.pas:65-67, 71-72, 80-81, 85-86, 90-92` — imza sırası/varsayılanları aynen dağınık (`VdbOpenReadOnly` BusyMs sonda `=0`; `VdbOpenWithBusyTimeout` BusyMs başta zorunlu; `VdbOpenWithPassword` sonda `=VDB_DEF_BUSY_MS`). `EVdbFactory` kodsuz (`VDbFactory.pas:41`). `VdbResolveFile` (`:99-113`) uzantısız var olmayan yolu sessizce dizine çeviriyor. Kilit yarışı tutarsızlığı: `:238-242` gerekçeli kaçınma vs `:258`/`:280` riskli `VdbFamilyOfFile` çağrısı.

**11 — F-ORTA-4 [ORTA] GEÇERLİ.** `VDbTable.pas:14-17` interface uses'inde `VDbCore` + `VDbBackendV2`; `TVTableDb.Create(AKv: TVDb)` (`:616`, gövde `:5100-5104` → `FKvB := TVDbBackendV2.Create(FKv)`). `yonetim/hadmain.pas.backup` hâlâ depoda. İyi örnek `hadmain.pas`'taki fabrika yolu duruyor.

**12 — F-ORTA-5 [ORTA] GEÇERLİ.** `VDbBackendApi.pas` değişmedi: `Delete`/`Get` Boolean (`:81-82`), `RollbackToSavepoint/ReleaseSavepoint` False=yok (`:156-157`) vs `Savepoint` istisna (`:148-150`), `AutoCompact` (`:250-252`), `LogPrune` çift kanal (`:312-314`), `Verify` `out Report` (`:220`), `LogStatus` string (`:274`), `Count: Integer` vs `CountTable: Int64` (`:84, :103`).

**13 — F-ORTA-6 [ORTA] GEÇERLİ.** `VDbExecutor.pas:25-29` interface uses 27 birim (`VDbArrow, VDbParquet, VDbXml, VDbVector, VDbSpatial, VDbReplication, VDbReplV3, VDbChangeLog, VDbMonitor, VDbCost, VDbExtension, VDbPlatform, VDbTrace…`); `VDbSql.pas:24` kendi interface'inde yeniden açıyor. **Bayat yorum:** `VDbExecutor.pas:46-49` ("VDbTable'in implementation uses'i VDbExecutor olduğu için…") hâlâ yanlış — `VDbTable.pas:1083-1085` yalnız `VDbMM, VDbSync, VDbParallel`. `PDummy` hilesi: `VDbTable.pas:23`. Dairesel bağımlılık: yine yok (yeni birim eklenmedi; 7 dosyalık çalışma uses dokunmadı).

**14 — F-DÜŞÜK-1 [DÜŞÜK] GEÇERLİ.** `VDbPageCrypto.pas:33` (`VDB_ENC_ENVELOPE = … + 4096 + …`) + `:136-165` 4096'lar; `VDbExecutor.pas:13765` `div 4096`; `VDbIdxFile.pas:228` (`Hdr.PageSize <> 4096`), `:376` (`h.PageSize := 4096`); `VDbPageWal.pas:677, 679, 689, 824, 843` — `WalCrc(..., 16, ...)` literal 16 (5 site; `VDB_WAL_REC_HDR` yalnız `:679`'da offset için). Olumlu: `VDbPageStore` tutarlı `VDB_PAGE_SIZE` kullanımı; yeni kod (C-13) `VDB_ENC_ENVELOPE`/`VDB_PAGE_SIZE` sabitlerini kullanıyor — doğru üslup.

**15 — F-DÜŞÜK-2 [DÜŞÜK] GEÇERLİ.** P-67 bayrak kurma döngüsü hâlâ 3 kopya: `VDbTable.pas:10444-10451`, `:10481-10488`, `:10508-10515`. `ResetBatchTableCache` 7 çağrı noktası (`:5164, 6328, 6370, 6402, 6409, 6429, 6452`). Yeni B-4 geçersiz kılma da tek satırlık `FOpenTDefValid := False` olarak **3 yere** dağıtıldı (`:5663, 5995, 6391`) — aynı "elle senkron" riskini yeni alan için yeniden üretiyor (bkz. R2-F-1).

**16 — F-DÜŞÜK-3 [DÜŞÜK] GEÇERLİ.** Mojibake sürdü; güncel ağacın örnekleri: `VDbExecutor.pas:32-33` (`tekilleÅŸtirme`), `:174` (`dÄ±ÅŸ satÄ±r baÄŸlamÄ±`), `:189`, `:2709-2710`, `:14462`, `:15202`; `VDbSql.pas:257, 321, 2977`; `VDbTable.pas:33, 173-174, 7125-7135, 9916, 9948, 11529-11530`; `VDbSpatial.pas:3`; `VDbXml.pas:424, 447`. **Olumlu:** commit edilmemiş çalışmanın yeni yorumları (B-x/C-x/R-A-x) saf-ASCII ve okunur — yeni kodda bozulma yok.

**17 — F-DÜŞÜK-4 [DÜŞÜK] GEÇERLİ.** Kökte `VDbBackendApi.s`, `VDbCrc32.s`, `VDbErr.s`, `VDbSync.s`, `VDbTypes.s`; `yonetim/hadmain.pas.backup` + `had.exe/had1.exe/hadESKI.exe`; `tests/gates/*.exe` (16 adet); `tests/sql/` altında yüzlerce `.o/.ppu` + `sqltest.exe`; `tests/bench/` altında birikmiş çıktılar (`p106s1/`, `p110*`, `p111sql*`, `hello2`, `joindiag`, `sp2test`, `scanpushbench`, `sp3out`…); takip edilmeyen `chainnull/`, `wherenull/`, `sıkıntı.md` (ad UTF-8 bozuk: `s\304\261z\304\261nt\304\261.md`) ve `tests/bench/*.lpr` (bdiag, probe, tansitest). `.gitignore` `*.exe`/`*.ppu` gizliyor ama ağaçta duruyorlar; `chainnull/`, `wherenull/`, bench çıktıları ignore'da değil.

**18 — F-BİLGİ-1 [ORTA→KISMEN].** Çürütme doğru ve duruyor: `FBatchHasIdentity/FBatchHasGenerated` okunuyor — `VDbTable.pas:10583-10587` (`if FBatchHasIdentity then ApplyIdentity(...)`, `if FBatchHasGenerated then VDbApplyGenerated(...)`) + doğrudan çağrılar `:11777-11778, 11930-11931`. **Kalan riskin non-batch dalı kapandı:** B-4, `FOpenTDef` yenilendiğinde `FPrefixCacheName := ''` yaparak (`:10500`) P-67 bayraklarının yeniden hesaplanmasını zorluyor; `LoadSchema` artık `FOpenTDefValid := False` (`:5663`). **Ama batch dalı (D-1a) KRİTİK olarak açık** → R2-F-1.

**19 — F-BİLGİ-2a [BİLGİ] GEÇERLİ.** `VDbBackendApi.pas:339-341` `TVdbBackendKvStore` yorumunun arasına `:342` `EVdbBackendApi = class(Exception);` sıkışmış; sınıf `:344`'te başlıyor. Değişmedi.

**20 — F-BİLGİ-2b [BİLGİ] GEÇERLİ.** `TVDbRowTagFunc` (`:37`) / `TVdbSessionIdFunc` (`:57`) / `IVDbBackend` (`:72`) / `TVdbBackendKvStore` (`:344`) büyük-küçük harf üslubu dağınık; `IVDbKvStore.ScanAll` (`:65-66`) varsayılan-parametresiz vs `IVDbBackend.ScanAll` (`:87-88`) `TableFilter: Integer = -1`.

---

## KISIM 2 — YENİ DENETİM (R2-F-1 …)

Yeni denetim iki kaynağa dayanıyor: (a) 7 dosyalık commit edilmemiş değişikliklerin satır satır incelenmesi (diff'ler: `VDbPageHeap` R-A-3/R-A-4, `VDbPageWal` C-13/C-14/C-15, `VDbPageEngine` B-18, `VDbPageStore` R-A-11, `VDbBackendV3` B-13/C-2/C-6, `VDbTable` B-3/B-4/B-11, `VDbExecutor` B-8 + FT.* batch dönüşümü — etiketler `DERINLEMESINE_INCELEME.md` bulgu kimlikleriyle eşleşiyor), (b) aynı eksenin güncel taraması.

### [R2-F-1 — KRİTİK] B-4 düzeltmesi D-1a KRİTİK'ini kapatmıyor: batch içi bayat şema/bayrak önbelleği hâlâ açık

`DERINLEMESINE_INCELEME.md:25, 813-851` (6 KRİTİK'ten biri, "öncelik 1"): `BEGIN; INSERT t; ALTER t; INSERT t` → 2. INSERT bayat `FBatchTableDef` kullanır, `VDbApplyGenerated`/`ApplyIdentity` atlanır → **yanlış sorgu sonucu**.

Commit edilmemiş çalışma bu bulguya B-4 ile yanıt veriyor ama **yalnızca non-batch dalı** geçersiz kılıyor:
- Eklenen: `FOpenTDefValid` alanı (`VDbTable.pas:363-366`), sıfırlama `LoadSchema` (`:5663`), `MarkSchema` (`:5995`), `ResetBatchTableCache` (`:6391`); kullanım `:10496-10501`.
- **Dokunulmayan:** `MarkSchema` (`:5992-6001`) `FBatchTableCached`, `FBatchTableDef`, `FBatchColMapValid`, `FBatchHasIdentity/FBatchHasGenerated`, `FPrefixCacheName`'i sıfırlamıyor. Bu alanların tek sıfırlayıcısı `ResetBatchTableCache` (`:6376-6393`) ve o yalnız batch yaşam döngüsünde çağrılıyor (`:6402, 6409, 6429`) + `:5164, 6328, 6370, 6452`.
- Kanıt: `FBatchTableCached :=` yalnız `:6381` (reset) ve `:10475` (Insert kurulumu) — hiçbir DDL yolunda yok. DDL yolları `MarkSchema` çağırıyor (`:11450, 11470, 11511, 11542, 11571, 11638, 11659, 11719, 10200, 10349` …) ve batch içinde DDL destekleniyor (`VDbTable.pas:6397-6399` BeginBatch yorumu: "DDL … batch içinde yapılabililsin diye sema yedeği alınır").
- Vektör: `BEGIN; INSERT INTO t …; ALTER TABLE t ADD/DROP COLUMN …; INSERT INTO t …` → 2. INSERT `FBatchColMap`/`FBatchTableDef` bayat; DROP COLUMN'da indeks kayması → yanlış kolona değer ya da aralık hatası; identity/generated kolon eklenirse sessiz boş değer.

Aynı raporun önerdiği en dar düzeltme ("`AlterAddColumn/DropColumn/...` gövdesine `ResetBatchTableCache` ekle", `DERINLEMESINE_INCELEME.md:917`) uygulanmamış.

### [R2-F-2 — ORTA] C-2: `.gen` fallback yolu "nesil sayacını koru" niyetini çiğniyor; kısmi-bayt yolu doğrulanamadı

`VDbBackendV3.pas:3925-3962` (SwapDbFileWith): yorum "Nesil sayacını (offset 0) KORU; yalnız durabil LSN alanını (offset 8) sıfırla" diyor. Normal yol doğru (`:3937-3945`, yalnız 8..15 sıfırlanır + fsync). Ama hata yolu (`:3953-3961`) **tüm `.gen` dosyasını siliyor** — offset-0 nesil sayacı dahil. `.gen` "yalnız ipucudur" (`VDbPageStore.pas:1217`) diye etki sınırlı olsa da, başka süreçlerin bayatlık sezgisini (`GenStamp`, `VDbPageStore.pas:372-375`) sıfırlar; yorum ile kodun niyeti zıt. Ayrıca `gs.Size < 16` ise (`:3937`) hiçbir şey yazılmadan `genOk := True` yapılıyor — yorum "OpenEx alanı 0 ile oluşturur/genişletir" diyor; bu **doğrulanamadı (ŞÜPHELİ)**: 8..Size arası bayat LSN bitleri sıfırlanmamış kalabilir. Olumlu: `FreeAndNil(FEng)` (`:3902`) manipülasyondan önce — kendi kendini kilitleme yok; `try/finally gs.Free` yapısı doğru.

### [R2-F-3 — ORTA] C-6: ikincil `AwaitDurable` istisnası sessizce yok ediliyor; yeniden-raise stack trace'ini kaydırır

`VDbBackendV3.pas` commit yolu (`~2889-3070`): `LogFinish/MaybeCheckpoint/MaybeAutoCompact` istisnaları `AcquireExceptionObject` ile (`pendExc`) tutuluyor, kilitler bırakıldıktan sonra `AwaitDurable` garanti ediliyor — **fikir doğru ve önemli** (durabilite beklemesinin atlanmasını önlüyor). Sorunlar:
1. İkincil `AwaitDurable` hatası `tmpExc.Free` ile **imha ediliyor** (`pendExc <> nil` dalı) — yorum "serbest bırakılır" diyor, kod siliyor. İkincil fsync/durabilite hatası loglanmıyor; birincil hata altında kayboluyor (teşhis kaybı).
2. `raise Exception(pendExc)` ile sonradan fırlatma FPC'de çalışır ama istisnanın `RaiseAddr`'ini yeniden-raise noktasına taşır; ham yığın izi orijinal noktayı göstermez (hata ayıklama maliyeti).
3. `pendExc` yakalandıktan sonra `finally` içindeki `ReleaseDataWrite`/`ReleaseWriteHold` patlarsa `pendExc` bellekten düşer (küçük sızıntı, kritik değil).
Şiddet ORTA (dayanıklılık güvencesi için değerli bir düzeltme; kalan kusurlar teşhis/çapraz sorun).

### [R2-F-4 — ORTA, ŞÜPHELİ] C-14: fsync hatasında tampon sıfırlama — "tekrar yazım" ile "sessiz kayıp" takası doğrulanmamış varsayıma dayanıyor

`VDbPageWal.pas:697-712`: `VDbFlushStream` (fsync) istisna atarsa `FBufferCount := 0; BufHashClear; SetLength(FOutBuf, 0)` + yeniden fırlatma. Yorumun varsayımı: "kayıtlar WriteBuffer ile dosyaya zaten yazıldı". Bu varsayım **tam değil (ŞÜPHELİ)**: fsync hatası (disk dolu/aygıt hatası) yazının OS önbelleğinden diske geçmediğini ima edebilir; tampon sıfırlanırsa yeniden deneme yolu kayıtları bir daha yazmaz → WAL'de sessiz kayıt kaybı, buna karşılık `FLSN`/`FWrittenBytes` ilerlemiş durumda. Alternatif (tamponu koru) tekrar yazım yapardı — ama kurtarma yolu sayfaları `AddTo` ile tekilleştiriyor (`VDbPageWal.pas:873-879` "tekillik zaten AddTo'da"), yani tekrar yazım muhtemelen zararsızdı. Karar savunulabilir ama savunulmamış; en azından hatanın loglanması gerekirdi.

### [R2-F-5 — DÜŞÜK] R-A-4: sihirli sınır + sessiz serbest bırakma + `FPageType` kalıntısı (ŞÜPHELİ)

`VDbPageHeap.pas:46-48` `VDB_OVF_MAX_STEPS = 1000000` — yeni sihirli sayı (F-DÜŞÜK-1 ile aynı üslup sorunu; gerekçesi yorumda ama sabit değil). `ReadOverflow` sınırda `FLastErr` ile döner (`:538-548`) — iyi; `FreeOverflow` ise **sessizce** `Exit` (`:596-610`) — sayfa sızıntısı sessiz kalıyor (kabul edilebilir "en iyi çaba", ama belgelenmemiş). `WriteOverflow` geri alma yolu (`except` bloğu) yalnız `curNo` için `FPageType[curNo] := 0` yapıyor; `FreeOverflow(nextNo)` ile serbest bırakılan zincir sayfalarının `FPageType[] = 2` kalıntıları temizleniyor mu doğrulanamadı (ŞÜPHELİ) — kirli tip haritası sonraki taramalarda yanlış tipte sayfa gösterebilir.

### [R2-F-6 — YÜKSEK] Yeni hata yollarının tamamı testsiz ve sınanması için altyapı yok

Aşağıdaki yollar yalnızca hata/arıza enjeksiyonu ile tetiklenebilir; `tests/gates` + `tests/sql` içinde böyle bir mekanizma yok (kapılar yalnız "kalan=0" / beklenen dize denetliyor):
- R-A-3 `WriteOverflow` except/geri alma (`VDbPageHeap.pas:483-513`)
- R-A-4 adım sınırı (bozuk/kendine dönen tasma zinciri) — `chainnull`/`wherenull` çalışma dizinleri repoda değil (takip edilmeyen çıktı), `tests/bench/chainnull.lpr` kapı değil
- C-14 fsync hatası, C-6 commit yolu istisnası (`LogFinish/MaybeCheckpoint`), B-18 grup-fsync istisnası (`VDbPageEngine.pas:937-960`), R-A-11 kurulum yarım kalması (`VDbPageStore.pas:657-665`)
- C-2 fallback (.gen silme → raise) ve çok süreçli `.gen` paylaşımı
Ek olarak: derleme izleri (madde 4) güncel ağacı kapsamadığı için bu 297 satırlık değişiklik setinin **hiçbir doğrulaması yok** — çalışma "kanıtsız" durumda.

### [R2-F-7 — ORTA] VDbExecutor batch seviyesi dönüşümü doğru yönde ama davranış değişikliği hedef testlenmemiş

`FT.Backend.BeginBatch/CommitBatch` → `FT.BeginBatch/FT.CommitBatch` (6 site: `VDbExecutor.pas:15666, 15800, 16233, 16242, 17999, 18052, 18243, 18258`) + `FT.AbortBatch` ile simetrik eşleşme. Bu, `VDbExecutor.pas:19083`'teki yazılı kurala ("`FT.Kv.BeginBatch` DEĞİL") uyum ve **gerçek bir düzeltme**: artık `TVTableDb.CommitBatch` yan etkileri (`FlushAutoIncCache` `:6408`, `SaveSchema` `:6410-6411`, `ClearSavepoints` `:6413`, `ClearSchemaSnapshot` `:6414`) multi-row INSERT/UPDATE/DELETE yollarında çalışıyor; eski kodda P-31 auto-inc önbelleği bu yollarda yazılmıyordu. Ancak:
- Yeni yan etkiler davranış değiştirdi (örtük sema kaydı + savepoint temizliği + SnapshotSchema maliyeti) — sqltest'te multi-row VALUES örnekleri var (`sqltest.lpr:2730, 4071, 4571`…) ama **IDENTITY'li multi-row + çökme** (auto-inc sayacının dayanıklılığı) senaryosu yok.
- Üslup tutarsızlığı sürüyor: kontrol `FT.Backend.InBatch` (`:15665, 16232, 17998, 18242`) seviyesi başlangıçta `FT.BeginBatch` — semantik eşdeğer ama karışık (DÜŞÜK).

### [R2-F-8 — DÜŞÜK] Yeni performans önbellekleri (B-3/B-4/B-8/B-11) kod olarak sağlam ama davranış güvencesi yok

İnceleme sonucu — hepsi doğru görünüyor (olumlu), risk yalnız test güvencesi:
- **B-3 `FLastDirtyIdx`** (`VDbTable.pas:348-350`): geçersiz kılma 4/4 tutarlı (`:6392` reset, `:8003, 9602, 9614` Delete+reset, `:9427` Clear+reset); kurucu `:5164` → `ResetBatchTableCache` ile `-1`. `IndexOf`'u yalnız "ekleme" tarafında atlıyor (`:7858-7865`); diğer ekleme noktaları (`:7908, 7933, 7958`) önbelleği okumuyor → yanlış atlama yok.
- **B-4 `FOpenTDefValid`**: ad eşlemesi (`:10496` `FOpenTDef.Name <> VDbNorm(Table)`) + nesil bayrağı doğru; ama R2-F-1'deki eksik kapsam.
- **B-8 `retCi`/`retCiAll`** (`VDbExecutor.pas:15499-15511`): `hasReturning` bloğu içinde, `allColNames` (`:15451`) ve `cnames` view dönüşümü (`:15480-15485`) **sonrasında** hesaplanıyor — sıra doğru; döngü boyunca değişmeyen girdilerle eşdeğer sonuç.
- **B-11** (`VDbTable.pas:7111-7121` + `:7139-7141`): `VDbIsPureAscii` + `VDbHashKeyBytes(FPrefixCacheVal, …)` kalıbı `VDbHashKey` ile birebir eşdeğer (`VDbHashKey` pk'yı normalize etmez, `:1349-1363`; UTF-8 birleştirme kararlı; `VDbHashKeyPrefix` ara-sıfır düzeltmesi bilinçli olarak yapmıyor `:1395`) — Insert'teki P-56 ile aynı idiom (`:10632-10633`). `HasIdxWork` kapısı P-65 ile aynı (`:7795-7809`, `:10667`).
- Buna karşılık bu dört önbelleğin **hiçbiri için hedef test yok**; bozuk geçersiz kılma = sessiz yanlış indeks/yanlış kolon eşlemesi üretir (bkz. test haritası).

### [R2-F-9 — DÜŞÜK] Temizlenmemiş yan meseleler: B-17/B-20 `ExclusiveAccess` yarışları, sihirli sayılar, mojibake

Çalışma, `DERINLEMESINE_INCELEME.md`'nin B-17 (`ExclusiveAccess` çalışma anında değiştirilebilir → MREW Lock/Unlock bozulması; `VDbTable.pas:5201-5230`) ve B-20 (TOCTOU, `:1214-1225`) bulgularını ele almamış — hem de `VDbTable.pas`/`VDbPageStore.pas` bu çalışma setindeyken. Ölü API'ler (`StoreGenStamp`, `BeginWrite/EndWrite`, `ExclusiveAccess` — KISIM 1 madde 5-7) ve F-DÜŞÜK-1/3/4 de aynen duruyor.

### [R2-F-10 — BİLGİ] Olumlu bulgular

- C-6'nın ana fikri (commit hatasında `AwaitDurable` garantisi), C-15 (`goodPos` kaydı — `VDbPageWal.pas:887-891` Break'ten önce son konum, incremental taramada tekrar okuma hatasını önlüyor), B-18 (`FSyncBusy` temizliği + bekleyen uyandırma `VDbPageEngine.pas:940-960`), R-A-11 (`FWriteCsInit` — `VDbPageStore.pas:185-187, 657-665, 710-711`) hepsi doğru yönde, yerinde ve küçük.
- B-4 eski F-BİLGİ-1 "kalan risk"ini (non-batch bayrak bayatlığı) fiilen kapattı.
- Yeni yorumlar saf-ASCII; `B-x/C-x/R-A-x` etiketleri `DERINLEMESINE_INCELEME.md` bulgu kimlikleriyle izlenebilir — iyi denetim izi.

---

## TEST KAPSAMI HARİTASI — commit edilmemiş değişiklikler ↔ güncel testler

Yöntem: `tests/gates/*.lpr` + `tests/sql/sqltest.lpr` `uses` listeleri ve test gövdelerinde isim/davranış taraması (derleme/çalıştırma yok).

| Değişen yol (dosya) | Mevcut kapsayan test | Kalan boşluk |
|---|---|---|
| `VDbPageHeap.WriteOverflow` geri alma (R-A-3) | `heapchk` (ovf testleri `heapchk.lpr:394+`), `crashtest`, `idxchk`, bench'ler | AllocPage/PageInsertCell başarısızlığı yolu **testsiz** |
| `ReadOverflow`/`FreeOverflow` adım sınırı (R-A-4) | `heapchk`, `idxchk`, `crashtest` (normal zincir) | Bozuk/kendine dönen zincir **testsiz** |
| `VDbPageWal.Bytes` şifreli boyut (C-13) | dolaylı: `crashtest`, `idxchk`; `sqltest` T76 (`sqltest.lpr:965+`) şifreli WAL replay | `Wal.Bytes`'e dayalı checkpoint kararı (`VDbBackendV3.pas:1618`) şifreli modda **testsiz** |
| `VDbPageWal.Flush` tampon sıfırlama (C-14) | — | **testsiz** (fsync hatası enjeksiyonu yok) |
| `VDbPageWal.Recover` `goodPos` (C-15) | `pitrchk` (AS OF TIMESTAMP/VERSION, `pitrchk.lpr:242, 285`) | Artımsal taramanın commit'i tekrar uygulamadığına dair **hedef doğrulama yok** (kısmi) |
| `VDbPageEngine` B-18 | — | **testsiz** (fsync hatası) |
| `VDbPageStore` R-A-11 | `storechk`, `lockchk`, `heapchk`, `crashtest` (normal yol) | Yarım kurulum yolu **testsiz** |
| `VDbBackendV3` C-6 | — | **testsiz** (commit yolu istisnası) |
| `VDbBackendV3` C-2 `.gen` sıfırlama | `sqltest` ALTER DATABASE KEY (`sqltest.lpr:16268-16342`), T75/T148 Compact | Fallback (.gen silme) + çok süreçli paylaşım **testsiz** |
| `VDbBackendV3` B-13 (RequireWritable tekilleştirme) | `v3sqlchk`, `sqltest` (davranış nötr) | — |
| `VDbTable` B-3 `FLastDirtyIdx` | dolaylı: `sqltest` UNIQUE/indeks testleri, `idxchk`, `btreechk` | Önbellek tutarlılığı için **hedef test yok** (DROP INDEX → aynı k ile ekleme dizisi) |
| `VDbTable` B-4 `FOpenTDefValid` | `sqltest` INSERT regresyonu | DDL arası non-batch INSERT geçersiz kılma; **D-1a batch yolu hem testsiz hem kırık** |
| `VDbTable` B-11 Update hash + `HasIdxWork` | `sqltest` UPDATE + indeks | ASCII-dışı pk fallback yalnız dolaylı |
| `VDbExecutor` B-8 RETURNING ön-hesap | `sqltest` R-04 (`sqltest.lpr:7511+`, view/UPSERT varyantları) | Multi-row VALUES + RETURNING kombinasyonu dolaylı |
| `VDbExecutor` `FT.*` batch dönüşümü | `sqltest` multi-row INSERT (`:2730, 4071, 4571`), UPDATE/DELETE batch'leri | IDENTITY'li multi-row + çökme (auto-inc dayanıklılığı) **testsiz** |

### "Nasıl sınanmalı" listesi (commit edilmemiş set için minimum)
1. `sqltest` **v2 + v3** tam koşum (ci.yml iki koşum — runall'da v2 yok!): multi-row VALUES, RETURNING, IDENTITY/GENERATED (M10), ALTER DATABASE KEY, şifreli WAL (T76).
2. `heapchk` + `crashtest` + `idxchk` (overflow/WAL replay normal yollar).
3. `pitrchk` (AS OF — C-15 pencere kesme).
4. `storechk`/`lockchk` (R-A-11 normal yolu), `v3sqlchk` (savepoint/DDL).
5. **Yazılması gereken yeni kapılar:** (a) bozuk tasma zinciri (R-A-4), (b) yazma/fsync hatası enjeksiyonu (R-A-3/C-14/C-6/B-18 — ortak bir `faultinj` test yardımcı birimiyle), (c) DDL-in-batch (D-1a) — R2-F-1 kapanana kadar bu test **kırmızı** beklenir, (d) B-3/B-4 önbellek geçersiz kılma dizileri.

### Hâlâ testsiz ana yollar (eski F-ORTA-1 listesi aynen geçerli)
`ExclusiveAccess` · `DurableOnFlush` · `BeginWrite/EndWrite` · `StoreGenStamp` · `WaitForeignTxn`/`RefreshBatchSnapshot` · WAL v1→v2 uyumu (`VDB_WAL_VER_COMPAT`, başlık-only `WalCrc`) · `VDbMM` · `VDbPool`, `VDbCdc`, `VDbDataSet`, `VDbTimeTravel` · `VDbArrow/VDbParquet/VDbXml/VDbVector` (doğrudan test yok).

---

## ÖNERİ ÖNCELİĞİ
1. **[R2-F-1, KRİTİK]** DDL yollarına (`MarkSchema` gövdesi en dar nokta) `ResetBatchTableCache` veya yalnız `FBatchTableDef/FBatchColMapValid/FBatchHas*/FPrefixCacheName` geçersiz kılma ekle; D-1a senaryosunu kapıya bağla.
2. **[R2-F-6, YÜKSEK]** Commit edilmemiş seti önce çalıştır (runall + sqltest v2/v3), sonra arıza-enjeksiyon testleri ekle (R-A-3/R-A-4/C-14/C-6/B-18).
3. **[R2-F-2/3/4, ORTA]** C-2 fallback'te `.gen`'i silmek yerine yalnız offset 8'i sıfırlamayı dene + sayacın korunduğunu doğrula; C-6'da ikincil istisnayı logla (imha etme); C-14'te kararın varsayımını yorumda gerekçelendir veya tamponu koru.
4. **[KISIM 1 YÜKSEK]** `EVdb*` istisnalarını `EVDbException.ErrorCode`'a bağla (VDbErr.pas:8-11 kuralı) — en azından `EVdbBackendV3.Savepoint` (`:3273`) `ecDuplicateSavepoint` ile fırlatsın; PgWire SQLSTATE zinciri ancak o zaman çalışır.
5. **[KISIM 1]** Ölü API üçlüsünü (`StoreGenStamp`, `BeginWrite/EndWrite`, `ExclusiveAccess`) bağla ya da API'den çıkar; `runall.sh`'a v2 sqltest + vdbmig + `atlanan=0` denetimi ekle.

---
*Bu rapor salt okunur inceleme sonucu üretilmiştir; hiçbir kaynak dosya değiştirilmemiş, hiçbir derleme/çalıştırma yapılmamıştır. Satır numaraları 06.11.2026 çalışma ağacı (HEAD `1fe0acf` + kirli 7 dosya) görseline göredir.*
---

# EK-G — UYGULAMA KAYDI (2026-11-06)

Bu ek, raporun yukaridaki bolumlerinde "gecerli" isaretlenen bulgularin
hangi commit'lerle kapatildigini ve kapatilmayanlarin gerekcesini kaydeder.
Kod yorumlarindaki `R2-*` etiketleri buradaki kimliklerle birebirdir.

## G.1 Duzeltildi

| Bulgu | Commit | Ozet |
|---|---|---|
| R2-A-1 / R2-B-1 | P-126 | `SlabBits` guncellemesi kilit altina alindi |
| R2-A-2 | P-126 | Yeni slab yayininda mevcut bump alani korunur, bos slab iade edilir |
| R2-A-3 | P-126 | `MMReallocMem`/`MMMemSize` slab basligini dogrular; bozuk baslikta sinir disi okuma yok |
| R2-A-5 | P-126 | `ActiveConnections` kiralamayla birlikte artar; `Release(nil)` sahipsiz mutex birakmaz |
| R2-A-6 | P-126 | `CreateXProc` `inherited Create` cagirir; destructor nil guvenli |
| R2-A-8 | P-126 | `FSeen` FIFO budama ile sinirli (`MaxSeen`, varsayilan 100000) |
| R2-A-9 | P-126 | Tampon tasmasi tek `DeleteRange` (O(k*n) -> O(k)) |
| R2-A-11 | P-126 | PgWire `Sync` portallari temizler |
| R2-A-12 | P-127 | COPY gecici dosya adi surec tokeni + atomik sayac; TOCTOU kalkti |
| R2-A-13 | P-126 | PgWire mesaj uretimi tek kapasiteli tampon |
| R2-A-14 | P-126 | `BuildAsOfRows` katlamali buyume |
| R2-B-4 | P-126 | `FIdxDirty` tek giris noktasi (`AddDirty`/`RemoveDirty`/`ClearDirty`) |
| R2-B-5 | P-126 | Havuz ornek sahipligi denetimi (yanlis thread Release -> acik hata) |
| R2-C-1 | P-127 | `AwaitDurable` hedefi guncel WAL uzayinda degilse beklemez |
| R2-C-3 | P-127 | fsync hatasinda WAL yazimi geri kirpilir (hayalet commit yok) |
| R2-C-4 | P-127 | `CommitCount` tarama imlecini geri yukler |
| R2-D-1 / R2-E-3 | P-126 | `PutRow` ayri prefix onbellegi kullanir; P-67 degismezi korunur |
| R2-D-2 / R2-D-3 / D-1a / R2-F-1 | P-126 | `MarkSchema` semadan turetilen tum batch onbelleklerini dusurur; FK kaskad commit/abort simetrik |
| R2-E-1 | P-126 | `FireTriggers` olu `TTableDef` kopyasi kaldirildi |
| R2-E-5 | P-126 | Non-batch Insert onbelleginde satir basina `VDbNorm` kaldirildi |
| R2-E-6 | P-126 | `INSERT ... SELECT` tek batch icinde atomik |
| R2-E-7 | P-126 | `INSERT () VALUES ()` yolundaki cift AFTER tetikleyici kaldirildi |
| B-5 / B-6 / B-12 (Tur-1 perf) | P-126 | Indeks kolon kopyasi, FK normalizasyonu, kismi indeks plan onbellegi |

Not: `ExecCreateView`'in katalogdaki dangling `SelectStmt` uzerinden sema
turetmesi (B-10 ailesi) P-126'da kapatildi; `StmtMutated` dalinda AST serbest
birakma da kaldirildi (sahiplik kataloğa devredilebilir).

## G.2 Kismen / gecersiz cikan iddialar

- **R2-C-2 (fsync hatasi yutuluyor):** Etki abartili. `AwaitDurable`
  basarisizlikta `FSyncErr` alanini KALICI olarak doldurur; sonraki tum
  `AwaitDurable` cagrilari ayni hatayi yeniden firlatir. Yani hata
  buharlasmiyor, ilk istemci yanitindan sonra da gorunur kaliyor. Ek alan
  eklemek gereksiz bulundu.
- **R2-A-4 (slab'lar OS'e iade edilmez):** Bilgi duzeyinde; tasarim tercihi
  olarak korundu.

## G.3 ERTELENENLER ve gerekceleri

| Bulgu | Gerekce |
|---|---|
| B-01 (ic ice taramada `FSnapMap` UAF) | Tarama callback'i, `FStreamCb/FStreamUser/FStreamAbort/FStreamFilter` alanlari ve `FSnapMap` backend nesnesinde TEK kopya. Dogru cozum tarama baglamini (context) cagri zinciri boyunca tasimak ya da tarama basina yigin tutmak; her iki secenek `StreamCbRaw` cagiran ~10 yuzeyi ve executor callback sozlesmesini degistirir. Tek oturumluk dilimde guvenli dogrulanamaz. |
| B-02 (`TryGetIdxSource`/`TryGetMemIndex` kilitsiz) | `TVTableDb` tum baglantilar arasinda paylasilir; bu fonksiyonlara tablo duzeyi bir kilit eklemek mevcut `LockRead` ve backend `FEngCs` kilit sirasiyla ters cevrilme riski tasir. Once kilit hiyerarsisi belgelenmeli (R2-B-3 ile birlikte). |
| R2-B-2 (`FBatchSet`/`FBatchSetSid` kilitsiz) | Ayni kilit hiyerarsisi calismasina bagli; tek basina kilit eklemek oturum izolasyonu semantigini degistirir. |
| R2-B-3 (paylasimli `FT` islem durumu) | Mimari: `TVTableDb`'nin oturum-bazli islem durumundan ayrilmasi gerekir. |
| C-1 / C-3 / C-16 (sayfa LSN damgasi, checkpoint budama) | Cok surecli kalicilik tasarimi; sayfa bicimine alan eklenmesi (surum yukseltmesi) ve kurtarma testleri gerektirir. |
| R2-F-6 (ariza enjeksiyonu test altyapisi) | Yeni test altyapisi isi; mevcut 20 kapi kapsamini degistirmeden ayri bir calisma olarak ele alinmali. |
| B1 / R2-E-2 / R2-A-15 (perf adaylari) | Olcum disiplini: >=%2 kazanc dogrulanmadan uygulanmaz; B1 (PK cift sondalama) bir sonraki olcum turunun ilk adayi. |
| R2-A-16 / R2-A-17 | Dusuk oncelikli, uretim disi yollarda; davranissal risk dusuk ama kazanc da yok. |

## G.4 Dogrulama

Her iki commit oncesi `tests/gates/runall.sh <dizin> -B` ile 20/20 kapi,
`sqltest --backend=v3` 2885 gecti / 0 kaldi / 33 atlandi, `wherenull` ve
`chainnull` TEMIZ alindi. (Not: eski derleme dizinlerindeki BAYAT `.ppu`
birimleri XML bolumunde 21 yanlis hata uretiyordu; taze `-FU` birim dizini
ile bu hatalar kaybolur. Kapilar bu yuzden taze dizinde kosulmalidir.)

---

# EK-H — Dogrulama turu (2026-11-06): P-126/P-127 duzeltmelerinin denetimi

Yontem: 4 bagimsiz dogrulama ajani (bellek / dogruluk / eszamanlilik / cokme),
salt okunur. Her bulgu icin karar: **TAM / KISMEN / YOK / YENI-RISK**.
Denetlenen commit'ler: `104cd86` (P-126), `2fcf91d` (P-127), ustte `ef41f04`.

## EK-H.1 Karar tablosu

| Bulgu | Karar | Kanit (guncel) |
|---|---|---|
| R2-A-1 SlabBits kilitsiz RMW | **TAM** | RMW artik `MMLock` icinde (`VDbMM.pas:160-182`); tek yazma noktasi, ic ice kilit yok |
| R2-A-5 VDbPool sayac kacagi | **TAM** | Kira 1:1 eslesme, `FMySlot > 0` korumali azaltma (`VDbPool.pas:298-302,313-319,486`) |
| R2-A-8 VDbCdc FSeen buyume | **TAM** | `FMaxSeen=100000` + FIFO budama (`VDbCdc.pas:351-363`) |
| R2-A-11 PgWire portal bellegi | **TAM** | `Portals.Clear` Sync'te (`VDbPgWire.pas:1929`, ayrica `1675,1916,1942`) |
| R2-A-12 COPY gecici dosya TOCTOU | **TAM** | PID token + atomik sayac + tik (`VDbPgWire.pas:1210-1224`); silme yalniz kendi dosyasi (`1338`) |
| R2-A-4 dogrulanmamis `len` on-tahsis | **YOK** | `VDbPageHeap.pas:530, 914-916, 1545-1547` ~2 GB on-tahsis + sinir-disi `Move` aynen |
| R2-D-1 PutRow P-67 bayrak bayatligi | **TAM** | `FPutPrefixName` ayri onbellek (`VDbTable.pas:7418-7429`); `FPrefixCacheName` tum yazim noktalari (`10773-10785, 10811-10821, 10836-10853`) bayraklarla birlikte |
| D-1a + R2-F-1 DDL-inside-batch bayat onbellek | **TAM** | `MarkSchema` -> `ResetBatchSchemaCaches` (`6230, 6630-6652`); ALTER + CREATE/DROP INDEX + TABLE + view/MV + RENAME + FK dahil her DDL |
| R2-D-2 indeks varyanti | **TAM** | MarkSchema sonrasi taze `T.Idx` (`10286 -> 10804-10808`); `HasIdxWork` Idx sayisini anahtar alir (`8119`); CONCURRENTLY batch reddi (`10180`) |
| R2-D-3 FK kaskad simetrisizlik | **TAM** | `CheckRestrict` commit `TVTableDb.CommitBatch` (`7650-7652`) — abort ile simetrik |
| R2-C-1 yarim VACUUM -> sonsuz fsync | **TAM** | `ALsn > WrittenLsn -> bekleme yok` (`VDbPageEngine.pas:885-892`); kalanti: `syncLsn` istisna yolunda hala sifirlanmiyor (`VDbBackendV3.pas:3040-3041`) |
| R2-C-3 hayalet commit | **KISMEN** | `Commit(DoSync=True)` yolunda geri kirpma (`VDbPageWal.pas:712-725`); grup-commit + C-6 istisna yollari acik |
| R2-C-2 ikincil fsync yutulmesi | **YOK** | `tmpExc.Free` ile yutuluyor (`VDbBackendV3.pas:3058-3073`) |
| R2-B-4 FLastDirtyIdx | **KISMEN** | Tek giris noktasi (`VDbBackendV3.pas:8128-8154`) yapisi dogru; `FlushIdxPending` hala okuma kilidinde yaziyor (`10095-10096 -> 9937,9947`) |
| R2-B-5 VDbPool sahiplik/UAF | **KISMEN** | `FOwners` denetimi (`VDbPool.pas:56-61,433,460-471`); instance-bazli named mutex (`220`) + capraz-thread `CloseEngine` (`247-268`) degismedi |
| B-06 VerifyNoConflict FAlien | **KISMEN** | `VDbBackendV3.pas:1793-1869` degismedi |
| B-01 FSnapMap UAF (KRITIK) | **YOK** | `FStream*` alanlari hala `FEngCs`'ten once yaziliyor (`VDbBackendV3.pas:2572-2575`); FSnapMap tek alan (`273,2042`); yigin tabanli tarama baglami yok — **EK-G'de bilincli ertelendi** |
| B-02 lazy indeks kilitsiz yazim (KRITIK) | **YOK** | `VDbTable.pas:9990-10145` kilit korumasiz; `LockRead` altinda cagri (`VDbSql.pas:3212-3234`) — **EK-G'de bilincli ertelendi** |
| R2-B-2 FBatchSet kilitsiz okuma | **YOK** | `VDbBackendV3.pas:1495-1496,1546`; `FBatchSetSid` commit'te sifirlanmiyor (`2999,3101`) — **EK-G'de bilincli ertelendi** |
| R2-B-3 FT.BeginBatch RequireSoleTxn | **YOK** | `VDbTable.pas:6654-6663` — **EK-G'de bilincli ertelendi** |
| B-05 FHoldDepth | **YOK** | `VDbPageStore.pas:1613-1617` aynen |
| B-07 ReadBytesAt kilit sizintisi | **YOK** | SH sizintisi hata yolunda (`VDbPageStore.pas:2063-2076`) |
| C-1 onayli sayfalarin budanmasi (KRITIK) | **YOK** | Truncate filtresiz (`VDbPageWal.pas:971-993`); Flush yalniz kirli (`VDbPageStore.pas:2743-2749`) |
| C-3 + C-16 sayfa LSN damgasi (KRITIK) | **YOK** | Damga yalniz deklare (`VDbPage.pas:65`) ve hep 0 (`:196`); okuma yolu denetimsiz (`VDbPageStore.pas:2255-2282`) |
| C-2 kalintisi (`.gen` devralma) | **YOK** | DROP+CREATE dosyalari silmiyor (`VDbSql.pas:3645-3649`); >=16 bayt `.gen` devraliniyor (`VDbPageStore.pas:1845-1865`) |
| D-Y1/Y2 SUM/AVG Double | **YOK** | Hala `Double` (`VDbExecutor.pas:1495, 8691, 8753, 10568`); Int64/Kahan yolu yok |

**Ozet: 12 TAM, 4 KISMEN, 11 YOK.** "Hepsi duzeldi" iddiasi P-126/P-127'nin
kendi kapsam (R2-A-12, R2-C-1/3/4 + R2-A/B/D/E/F guvenli kumeleri) icin
dogru; bilincli ertelenenler (B-01, B-02, R2-B-2, R2-B-3 — EK-G) ve
C-1, C-3/C-16, R2-A-4, D-Y1/Y2, R2-C-2, B-05, B-07 acik kalmistir.

## EK-H.2 Dogrulama turunda YENI bulgular

| # | Siddet | Bulgu | Yer |
|---|---|---|---|
| R2-D-YENI-1 | YUKSEK | Kolon haritasi onbellegi yalniz uzunluk + tablo adi ile dogrulaniyor → ayni transaction'da farkli kolon listeli iki INSERT bayat haritayla sessiz yanlis kolona yazar | `VDbTable.pas:10875-10887` |
| R2-D-YENI-2 | YUKSEK | MV satir sayaci kalici yazilmiyor → yeniden acilista MV bos gorunur, REFRESH eski satirlari silemez | `VDbTable.pas:11945-11948, 12031` |
| R2-C-YENI-1 | YUKSEK | `Refresh`'in `FWrittenLsn := FLSN` yazimi R2-C-1 erken cikisiyla yarisip fsync'i sessiz atlayabilir → yanlis durabil onaji | `VDbPageWal.pas:485-487` + `VDbPageEngine.pas:885-892` |
| R2-C-YENI-2 | YUKSEK | DROP+CREATE'de kalan eski `.wal` kurtarmada yeni DB'ye uygulanabilir (C-2 kalintisindan agir) | `VDbSql.pas:3645-3649` |
| R2-B-YENI-1 | ORTA | VDbPool `Release` hata yolunda ornek+slot+mutex sizintisi; TID yeniden kullanimi | `VDbPool.pas` |
| R2-B-YENI-2 | ORTA | `MMReallocMem` bozuk basta `nil` donup eski isaretciyi birakir | `VDbMM.pas` |

Notlar: `MMLock` tekrarli degil (gelecekte ic ice tahsis deadlock'u);
`AcquireSlot` artisi-kiralama arasi cokme sayimi dusuk birakir; R2-A-12'de
PID-geri-donusumu teorik pencere. Yeni kilit sirasi (AB-BA) yok; performans
gerilemesi olculemedi (statik denetim).

## EK-H.3 Oneirilen siradaki is (guncel)

1. **R2-D-YENI-1** kolon haritasi onbellegi — yanlis kolona yazim, oncelik 1.
2. **C-1 + C-3/C-16** (cok surecli kalici kayip; sayfa LSN damgasi dogrulamasi).
3. **R2-C-YENI-1/2** durabil onaji yanlisi + eski `.wal` devralma.
4. **B-01 + B-02 + R2-B-2 + R2-B-3** (EK-G'de ertelendi; hala KRITIK).
5. **R2-A-4** page-heap `len` sinir denetimi; **R2-C-2** fsync yutulmesi.
6. D-Y1/Y2 SUM/AVG hassasiyeti; B-05/B-07 kilit sizintilari.

# EK-I — P-128 uygulama kaydi (2026-11-06)

Kapsam: **B-01 + B-02 + R2-B-2 + R2-B-3**. EK-G'de ertelenen dort kalemin
uygulanmasi; ayrica karsi denetimde (A4) cikan ve kapsama giren P-129
duzeltmesi.

## EK-I.1 Yapilan degisiklikler

| Kalem | Yer | Ozet |
|---|---|---|
| B-01 | `VDbBackendV3.pas` `ScanAll`, `ScanRawIterAll`, `ScanRawIterAllPaged` | Tarama alanlari (`FStream*`, `FScan*`, `FSnapMap`) `FEngCs` altinda kaydedilip geri yuklenir; ic ice tarama dis taramanin baglamini ezmez, `FSnapMap` yalniz sahibi tarafindan serbest birakilir. |
| B-02 | `VDbTable.pas` yeni `FIdxCs` (yaprak) + `FIdxBuildCs` (seri insa) | Indeks onbellekleri kisa kritik bolgelerde korunur; tarama/siralama kilit DISINDA yapilir. Tembel insa `FLock -> FIdxBuildCs -> FEngCs -> FIdxCs` sirasini izler. |
| R2-B-2 | `VDbBackendV3.pas` batch yollari | `FBatchSet`/`FBatchSetSid` ciftinin yayin sirasi tanimlandi (yazarken once SID sonra isaretci; temizlerken once isaretci sonra SID; okuyucu once isaretci sonra SID). Kapanista cift sifirlanir. |
| R2-B-3 | `VDbTable.pas` sema yedegi/savepoint/ertelenen FK/CONCURRENTLY | Tum bu durumlar oturum kimligi (SID) tasir; abort/commit yalniz kendi kayitlarini geri alir. SID 0 ham API'nin eski global davranisini korur. |
| P-129 | `VDbTable.pas` `FConcCs` | Iki paralel SELECT ayni anda `PollConcurrentIndexes` cagirabildigi icin CONCURRENTLY defteri ve finalize govdesi serilestirildi (ayni kaydin iki kez `Free` edilmesi onlendi). |

Belge: `dokuman/kilit_sirasi.md` (katman tablosu, 8 degismez kural, kalan
riskler). Kapi: `tests/gates/concurchk.lpr` (+ `.lpi`, `runall.sh`, CI).

## EK-I.2 Dogrulama

- Tam kapi seti taze dizinde: **21/21 GECTI** (`runall.sh tmp64/c1/gates12 -B`).
- `concurchk`: paylasilan tek `TVdbBackendV3` + tek `TVTableDb`, baglanti
  basina ayri `TVSql`; 30/30 (paralel indeksli SELECT/INSERT, ic ice tarama,
  iki oturumun BEGIN/ROLLBACK ve ertelenen FK sahipligi).
- `wherenull` / `chainnull`: `SONUC: gecen=hepsi kalan=0` — TEMIZ.

Not: calisma agacinda ayri bir isin (C-1/C-3/C-16) commit edilmemis
degisiklikleri vardi; P-128 dogrulamasi bu degisiklikler gecici olarak
kenara alinarak yapildi (stash), ardindan geri yuklendi. C-16 su an
`dropchk`'i kirdigi icin P-128 commit'ine dahil edilmedi.

## EK-I.3 Karsi denetim (A4) triyaji

| # | Bulgu | Karar |
|---|---|---|
| R1 | `Src.Skip` odunc omru: okuyucu yinelerken baska yol listeyi degistirip serbest birakabilir | **ERTELENDI** — kalici cozum referans sayimi/kopya; EK-I.4 |
| R2 | `PollConcurrentIndexes` kilitsiz defter (cift `Free`) | **DUZELTILDI** — P-129 `FConcCs` |
| R3 | `FIdxBuildCs` <-> `FEngCs` ters cevrilmesi (ic ice akis alt sorgusu) | **ERTELENDI** — bugun planlayici insayi `FEngCs` disinda yapiyor; yeni ic ice insa noktasi eklenirse risk |
| R4 | `RestoreSchemaSnapshot` baska oturumun AutoInc'ini ezme | **ERTELENDI** — DDL/DML `FLock` yazma ile serilesiyor; oturum bazli sayac ayri is |
| R5 | `Destroy`'ta `FBatchSet` temizlenmemesi | **DUZELTILDI** — kapanista `FBatchSet := nil; FBatchSetSid := 0` |
| R6 | "`FIdxCs` yaprak degil yinelemeli" metin celiskisi | **DUZELTILDI** — kod yorumu + belge: ayni thread'de ic ice giris serbest, "yaprak" baska kilitlerin alinmamasidir |
| R7 | `PollConcurrentIndexes` FIdxCs altinda agir is | **KISMEN** — UNIQUE haritasi icin liste kopyasi `FIdxCs` altinda kaliyor (bellek ici, O(n)); skip/siralama/flush zaten kilit disinda |

## EK-I.4 Ertelenenler (gerekce)

1. **R1 `Src.Skip` yasam suresi.** Skip listesine referans sayimi eklemek
   veya okuyucuya kopya vermek `TryGetIdxSource` sozlesmesini ve tum
   cagiranlari degistirir; tek noktada guvenli yapilamaz.
2. **R3 ic ice insa kilidi.** `FEngCs` tutulurken `FIdxBuildCs` alinmasini
   engellemek icin gate derinligine `TVTableDb`'den erisim (arayuz
   genisletmesi) gerekir; planlayici bugun bunu tetiklemiyor.
3. **R4 oturum bazli AutoInc.** `FAutoInc` su an tablo basina tek sayac;
   oturum ayrimi kalici bicim/sema degisikligi ister.
