# VDB v3 — Derinlemesine Kod İnceleme Raporu

**Tarih:** 2026-11-06 · **Dal:** `v3` · **İnceleme anındaki HEAD:** `8b98b01` (P-97)
**Yöntem:** 6 paralel uzman ajan, salt okunur statik inceleme (hiçbir kaynak dosya değiştirilmedi, derleme/çalıştırma yapılmadı).
**Kapsam:** Bellek/kaynak yaşam döngüsü · Eşzamanlılık/kilitleme · Çökme güvenliği/dayanıklılık · İşlevsel doğruluk · Performans · Mimari/API/test boşlukları.

> **Anlık görüntü uyarısı:** İnceleme sırasında başka oturumlar ağacı eşzamanlı değiştirdi (P-110…P-125 arası commit'ler, `VDbTable.pas` üzerinde yazılıp geri alınan değişiklikler). Bazı satır numaraları inceleme anındaki görsele göredir; düzeltmeye başlarken ilgili kodu yeniden konumlandırın.

---

## 1. Yönetici özeti

**Toplam: 78 statik bulgu + 14 performans fırsatı.**
Şiddet dağılımı: **6 KRİTİK**, 19 YÜKSEK, 25 ORTA, 15 DÜŞÜK, 9 BİLGİ (+4 şüpheli madde).

Öncelik 1 (asla veri kaybı / yanlış sorgu sonucu olmasın) açısından **acil** olan altı konu:

| # | Bulgu | Eksen | Etki |
|---|---|---|---|
| 1 | **C-1** Checkpoint/Truncate, veri dosyasına hiç yazılmamış onaylı sayfaları WAL'den budar (`VDbPageEngine.pas:1119-1127`, `VDbPageWal.pas:943`) | C | Çok süreçli kullanımda **onaylı commit'ler kalıcı kaybolur** |
| 2 | **C-2** VACUUM/RESTORE/REKEY'de `.gen` silinmez, bayat durabil LSN monoton kalır → `AwaitDurable` fsync'i atlar (`VDbBackendV3.pas:3885`, `VDbPageEngine.pas:892-899`) | C | fsync yapılmadan "durabil" onayı; çökmede kayıp |
| 3 | **C-3** Temiz kurulum + önbellek tahliyesi + `MinLSN` atlama zinciri → eski sayfa diskten sessizce geri gelir; sayfa LSN damgası hiç denetlenmiyor (C-16) (`VDbPageWal.pas:805`) | C | Çalışma zamanında **sessiz veri bozulması** |
| 4 | **B-01** İç içe/paralel tarama, backend'e özel paylaşılan tarama durumunu (`FScan*/FSnapMap`) bozar; alanlar kilit dışına yazılıyor, correlated alt sorgu `FSnapMap`'i use-after-free ediyor (`VDbBackendV3.pas:2562-2568, 2611`) | B | Yanlış sorgu sonucu + çökme |
| 5 | **B-02** Tembel indeks yapıları (`FMemIdx/FSkipIdx/FIdxDirty/FPkIdx`) `LockRead` altında mutate ediliyor; paralel SELECT'ler ortak `TVTableDb`'de sözlük yarışı (`VDbTable.pas:9696-9778`, `VDbSqlServer.pas:86,169`) | B | Dictionary bozulması → çökme / yanlış sorgu sonucu |
| 6 | **D-1a** DDL-inside-batch sonrası **bayat şema/bayrak önbelleği**: `BEGIN; INSERT A; ALTER A; INSERT A` → 2. INSERT bayat `FBatchTableDef` kullanır, `VDbApplyGenerated` atlanır (`VDbTable.pas`) | D | Yanlış sorgu sonucu (tek iş parçacığında, transaction içinde erişilebilir) |

### İnceleme sırasında çürüyen/yanlış çıkan iki iddia (düzeltme)

1. **"P-67 ölü kod / bayraklar hiç okunmuyor" — YANLIŞ.** P-67 tamamlanmış ve commit edilmiş; `FBatchHasIdentity`/`FBatchHasGenerated` okunuyor, çağrılar koşullu (`VDbTable.pas:10539-10543, 10593-10597`). Gerçek açık vektör **D-1a'daki DDL-inside-batch bayat önbelleğidir**; literal "non-batch B araya girme" senaryosu normal transaction'da erişilemez.
2. **"31 Ekim P-50…P-66 için hiç test koşulmadı" — KISMEN YANLIŞ.** Commit mesajlarında sqltest 3287/0/0 kayıtları ve 02.11'de 20/20 kapı koşusu var. **Kalan gerçek borç:** inceleme anındaki HEAD (`8b98b01`) için taze test kaydı yok; son kayıtlar kaynaklardan eski.

### Hata yönetimi ve API (özet)

- **7 istisna sınıfı, 3 kodlama şeması.** Aynı SAVEPOINT hatası `VDbTable.pas:6351`'de kodlu `EVDbException`, `VDbBackendV3.pas:3242`'de kodsuz istisna; `VDbPgWire` SQLSTATE eşlemesi kırık. (F-YÜKSEK-1)
- **Ölü/erişilemez API:** `StoreGenStamp` (v3.18 çapraz süreç DDL) hiç çağrılmıyor; `BeginWrite/EndWrite` hiç bağlanmamış; `ExclusiveAccess` hiç `True` yapılmıyor → P-58c/P-60 kilit atlama yolu hem erişilemez hem testsiz. (F-YÜKSEK-3/4)

### Performans (öncelik 2 — hedef: tablo API 6,39 → SQLite 3,12 µs/satır)

En büyük üç kazanç adayı (tümü **tahmin**, doğrulanması ölçümle şart):

1. **B1** — PK varlık denetimi çift sondalama: her INSERT'te 2× hash + 2× `Copy`; tahmini **0,8–1,8 µs/satır**. En düşük riskli, en büyük aday.
2. **B3** — `IdxAddRow` koordinasyonu (`AddOrSetValue`/`IndexOf`/satır başına tahsis): tahmini **0,4–1,5 µs/satır** (indeksli tabloda).
3. **B2** — oto-PK/IDENTITY'de satır başına tam `ReadRow` + kendini-onarma denetimi: tahmini **0,5–1,5 µs/satır** (yalnız oto-PK'lı tabloda).

Depo katmanı (PutRaw 1,84 µs, grup fsync, sıralı batch) doygun; kalan fırsat satır başına katman geçişlerinde. Autocommit/fsync için **yeni dayanıklılık penceresi önerilmiyor** (kanıt yok, risk yüksek).

### Doğrulanan sağlam noktalar (denge)

Tek süreçli `Flush → fsync → AwaitDurable → Truncate` sırası, meta-sayfa-sonra-uygulama düzeni, CRC/tuz doğrulamaları, fsync hatalarının yutulmaması, WAL grup fsync (v3.19), `COUNT(*)` O(1), sınır durumları/DecodeRow/UNIQUE-NULL/IdxAddRow doğruluk testleri sağlam bulundu.

---

## 2. Konsolide öncelik listesi (önerilen düzeltme sırası)

| Sıra | İş | Kanıt | Neden önce |
|---|---|---|---|
| 1 | **C-1/C-2/C-3** dayanıklılık zinciri (checkpoint budama politikası, `.gen` LSN sıfırlama, sayfa LSN damgası doğrulaması) | r_C | Öncelik 1: çok süreçli veri kaybı + sessiz bozulma |
| 2 | **B-01** tarama durumunu stack'e alma | r_B | Öncelik 1: yanlış sonuç + use-after-free |
| 3 | **B-02** lazy indeks kurulumuna ayrı kilit | r_B | Öncelik 1: sözlük yarışı |
| 4 | **D-1a** DDL'de batch şema/bayrak önbelleğini geçersiz kılma | r_D | Öncelik 1: yanlış sonuç |
| 5 | **R-A-2** DoCommit exception yolunda pin/kilidin bırakılması, **B-03/B-04** `FDeferCount` sızıntısı, **B-07/B-08** kilit defteri tutarlılığı | r_A, r_B | Kilit takılması = erişilemez DB |
| 6 | **C-4…C-8** kalan dayanıklılık YÜKSEK'ları | r_C | Asılı kalan `AwaitDurable`, yanlış durum raporu |
| 7 | **F-Y1** hata yönetimi birleştirme (tek istisna sözleşmesi) | r_F | API güvenilirliği, PgWire SQLSTATE |
| 8 | **D-Y1/Y2** SUM/AVG `Double` hassasiyeti (>2^53) | r_D | Yanlış sayısal sonuç |
| 9 | **B1/B3/B2** performans (ölçümle doğrulayarak) | r_E | Öncelik 2: SQLite boşluğu |
| 10 | **F-ORTA-1** test boşlukları + HEAD'de taze kapı/sqltest koşusu | r_F | Regresyon güvencesi |

---

## 3. Eksen başına bulgu sayıları

| Eksen | Dosya | Bulgu | KRİTİK | YÜKSEK | ORTA | DÜŞÜK | BİLGİ |
|---|---|---:|---:|---:|---:|---:|---:|
| A — Bellek/kaynak yaşam döngüsü | `tmp64/r_A.md` | 13 | 0 | 2 | 5 | 5 | 1 |
| B — Eşzamanlılık/kilitleme | `tmp64/r_B.md` | 20 | 2 | 6 | 9 | 1 | 2 |
| C — Çökme güvenliği/dayanıklılık | `tmp64/r_C.md` | 16 | 3 | 5 | 4 | 3 | 1 |
| D — İşlevsel doğruluk | `tmp64/r_D.md` | 9 | 1 | 2 | 1 | 2 | 2 |
| E — Performans fırsatları | `tmp64/r_E.md` | 14 | — | — | — | — | — |
| F — Mimari/API/test | `tmp64/r_F.md` | 20 | 0 | 4 | 6 | 4 | 2 |

Bulguların tamamı dosya:satır kanıtlıdır; doğrulanmamış olanlar "şüpheli" ibaresiyle işaretlenmiştir. Statik inceleme bulguları **düzeltilmeden önce yeniden konumlandırılmalı ve testle doğrulanmalıdır**.

---
---

# EKLER — Alt ajanların tam raporları

Aşağıdaki bölümler, her biri tek eksene odaklanan alt ajanların tam raporudur (`tmp64/r_A.md` … `tmp64/r_F.md` ile birebir aynı içerik).

---

# EK-A — Kaynak Yasam Dongusu ve Bellek Sizintisi

# R-A — Kaynak Yaşam Döngüsü ve Bellek Sızıntısı Denetimi (salt-okunur)

- **Kapsam:** `D:\veritabani` (dal v3), FPC 3.2.4 / Delphi modu / i386-win32
- **Tarih:** 2026-11-06
- **Yöntem:** Yalnızca kaynak okuma (derleme/çalıştırma yapılmadı). Her bulgu dosya:satır ile kanıtlanır; doğrulanamayanlar `şüpheli` işaretlidir.
- **Odak dosyalar:** VDbPageStore.pas, VDbPageWal.pas, VDbPageEngine.pas, VDbPageHeap.pas, VDbSync.pas, VDbCrc32.pas, VDbChangeLog.pas (tam okuma); VDbExecutor.pas, VDbTable.pas (hedefli tarama).

---

## Özet Tablo

| # | Şiddet | Dosya | Konu |
|---|--------|-------|------|
| 1 | YÜKSEK | VDbPageWal.pas | Recover tamponu tüm commit'li sayfaları bellekte tutar (OOM) + O(n²) dedup |
| 2 | YÜKSEK | VDbPageEngine.pas | DoCommit'te pin / işlem / I/O kilidi exception yolunda bırakılmıyor |
| 3 | ORTA | VDbPageHeap.pas | WriteOverflow exception'ında sahipsiz tasma sayfaları (disk alanı sızıntısı) |
| 4 | ORTA | VDbPageHeap.pas | ReadOverflow: çevrimsel zincir koruması yok + `len` doğrulanmadan Move |
| 5 | ORTA | VDbPageHeap.pas | FreeOverflow: çevrimsel zincir korumasız → sonsuz döngü / çift FreePage |
| 6 | ORTA | VDbTable.pas / VDbExecutor.pas | Arka arkaya nesne kurulumları try'dan önce → yarım kurulumda sızıntı |
| 7 | ORTA (şüpheli) | VDbSync.pas | Kilit defteri handle kapanınca temizlenmezse sahte "kilit bende" |
| 8 | DÜŞÜK | VDbPageStore.pas | ReadBytesAt raise yolunda kendi aldığı paylaşımlı kilit bırakılmıyor |
| 9 | DÜŞÜK | VDbPageHeap.pas | Update'te geri koyma başarısızsa kayıt kaybı (tasarım yorumuyla çelişir) |
| 10 | DÜŞÜK | VDbPageStore.pas | VerifyFreeList / DirtyPages: satır başına `SetLength(n+1)` → O(n²) kopyalama |
| 11 | DÜŞÜK | VDbPageStore.pas | Constructor yarıda kalırsa Destroy başlatılmamış CS'e DoneCriticalSection çağırır |
| 12 | DÜŞÜK | VDbPageStore.pas | Şifreli okuma/yazmada sayfa başına TBytes tahsisi (churn) |
| 13 | BİLGİ | Çeşitli | Temiz işlenen yerler ve tasarım gereği büyümeler |

---

## YÜKSEK

### R-A-1 · VDbPageWal.Recover: tüm commit'li sayfa imgalarının bellekte tutulması + O(n²) ekleme
**Kanıt:** `VDbPageWal.pas:723-726` (`pending`, `applied: TPendingArray`), `VDbPageWal.pas:730-746` (`AddTo`), `VDbPageWal.pas:861-896`

- `AddTo` her eklemeden önce `for k := 0 to n-1` ile tüm diziyi tarar (satır 735-740): aynı sayfa numarası için **O(n²)** doğrusal dedup.
- `SetLength(arr, n + 64)` (satır 741-742) 64'lük adımlarla büyür; her yeniden tahsis tüm 4KB'lik kayıtları kopyalar → toplam **kuadratik bellek kopyalama**.
- `applied` dizisi, kurtarma boyunca **her commit'li sayfanın 4KB'lik tam imajını** bellekte tutar (satır 867: `AddTo(applied, ...)`), ancak tarama bittikten sonra (satır 884-889) uygulanır. Uzun WAL'te bu, i386 süreç adres alanında (~2 GB) doğrudan OOM riskidir: 100.000 farklı sayfa ≈ 400 MB tek dizi.
- `TPendingArray` elemanı `TVDbPageBuf` (4KB) olduğundan `Move` kopyaları da ağırdır.

**Etki:** Büyük WAL ile açılış/kurtarma sırasında OOM çökmesi veya aşırı açılış süresi. Veri kaybı değil; kurtarma öncesi çökme.
**Öneri:** `applied` yerine sayfa numarası → son imaj eşlemesi (hash) veya doğrudan tek geçişte uygulama; dedup için hash kümesi.

### R-A-2 · DoCommit: exception yolunda pin, işlem ve I/O kilidi bırakılmıyor
**Kanıt:** `VDbPageEngine.pas:1003-1009` (adım 1), `VDbPageEngine.pas:1055-1074` (EndTxn / EndIoWrite yalnızca başarılı yolda)

```pascal
1005:  if FStore.GetPage(dirty[i], P) then
1006:  begin
1007:    FWal.AppendFrame(dirty[i], P);      // <- exception fırlatabilir (disk dolu/I/O)
1008:    FStore.Release(dirty[i], False);    // <- exception'da ULAŞILMAZ
1009:  end;
```

- `AppendFrame` exception fırlatırsa o sayfanın **pin'i kalıcı takılır**. Havuzda tüm slotlar pinlenirse tahliye yapılamaz → sonraki tüm işlemler bloklanır/havuz büyür.
- `FStore.EndTxn` (satır 1069) ve `FStore.EndIoWrite` (satır 1074) yalnızca başarılı yoldadır; exception'da `FInTxn = True` kalır ve **yazma kilidi bırakılmaz** → sonraki işlem başlatma denemeleri kilitlenir veya hata verir.
- Aynı desen `VDbPageEngine.pas:1015-1017` (FPending döngüsü) ve `1031-1041` (meta imajı) için de geçerlidir.

**Etki:** Disk hatası/fazla taşma anında motor kilitli/pinli kalır; süreç kapanana kadar veritabanı kullanılamaz.
**Öneri:** Döngüyü `try..finally` ile sarmalayıp her iterasyonda Release; DoCommit gövdesine `try..except` ile `EndTxn/EndIoWrite` sıfırlaması.

---

## ORTA

### R-A-3 · WriteOverflow: ortada exception olursa sahipsiz tasma sayfaları kalır
**Kanıt:** `VDbPageHeap.pas:443-483`

- `AllocPage` ("bos sayfa yok" → exception, `VDbPageHeap.pas` içinde raise) veya `PageSetCell` hatasında döngü exception'la kesilir; o ana kadar tahsis edilen tasma sayfaları (zincir başı `Result` dahil) hiçbir yere kaydedilmez ve **freelist'e dönmez**.
- Hücre henüz güncellenmediği için çökme olmaz ama sayfalar artık sahipsizdir (`UseCount` 1'de kalır, `PageMapRemove` yapılmaz) → disk alanı sızıntısı.
- `FreeOverflow`'un kendisi korumalı olduğu için bu bir veri bozulması değil, alan sızıntısıdır.

**Öneri:** Döngüyü `try..except` ile sarıp kısmi zinciri `FreeOverflow` ile geri almak (DeleteAt'teki `VDbPageHeap.pas:902-903` desenindeki gibi).

### R-A-4 · ReadOverflow: çevrimsel zincir koruması yok, `len` alanı doğrulanmıyor
**Kanıt:** `VDbPageHeap.pas:485-554`; karşılaştırma: `Verify`'daki koruma (`VDbPageHeap.pas:1177-1215` civarı)

- `while pageNo <> 0` döngüsünde ziyaret kümesi yok; `Verify`'da olan koruma burada **yok**. Bozuk/kendine işaret eden zincirde **sonsuz döngü** ve `SetLength(Result, n+sz)` ile **sınırsız bellek büyümesi** (her turda 4KB+ kopyalama).
- `sz = len - 8` hücrenin ham `len` alanından gelir; `dl` (PageGetCell'ın döndürdüğü gerçek hücre boyutu) ile **doğrulanmaz** (satır ~530-533: `Move(p^, Result[n], sz)`). `len > dl+8` ise sayfa tamponundan **taşma okuma** (AV veya yanlış veri) + dev tahsis.
- `if sz > PageSize then Break` yalnızca kısmi koruma sağlar.

**Etki:** Bozuk veritabanı dosyasında çökme / OOM / taşma okuma. Sağlam dosyada sorun çıkmaz (CRC korumalı sayfalar). Bu nedenle ORTA (bozuk dosya koşulu).
**Öneri:** Ziyaret kümesi + `len` doğrulaması (`sz <= dl - VDB_CELL_HDR`) eklenmeli.

### R-A-5 · FreeOverflow: çevrimsel zincir koruması yok
**Kanıt:** `VDbPageHeap.pas:556-577`

- Aynı `while pageNo <> 0` döngüsü, ziyaret kümesi yok. Kendine dönen zincirde **sonsuz döngü**; iki zincir aynı sayfayı paylaşıyorsa **çift FreePage** → freelist bozulması (aynı sayfa iki kez trunk zincirine eklenir → çift tahsis / veri bozulması).
- Çağrı noktası `DeleteAt` (`VDbPageHeap.pas:897-903`) yalnızca ilk sayfayı serbest bırakır; zincir gövdesi `FreeOverflow`'un doğruluğuna bağlıdır.

**Öneri:** Ziyaret kümesi veya adım sınırı; `FreePage` öncesi sayfanın zaten serbest olmadığını doğrula.

### R-A-6 · Arka arkaya nesne kurulumları try'dan önce (yarım kurulum sızıntısı)
**Kanıt:** `VDbTable.pas:5711` ve `VDbExecutor.pas:14245-14247`

```pascal
5711:  sl := TStringList.Create; parts := TStringList.Create; cp := TStringList.Create;
5712:  try
...
5734:    sl.Free; parts.Free; cp.Free;
```

```pascal
14245: QList := TStringList.Create;
14246: Cand := TStringList.Create;
14247: Counts := TDictionary<string, Integer>.Create;
14248: try
```

- İkinci/üçüncü `Create` (ör. OOM) exception fırlatırsa `try` bloğuna hiç girilmez ve önceki nesne(ler) **sızar**. Bu, "yarım kalmış nesne" kategorisinin klasik desenidir.
- Aynı desen `VDbExecutor.pas` içinde benzer çoklu-Create satırlarında tekrarlanıyor olabilir (hedefli tarama ile doğrulanan örnekler bunlar).

**Öneri:** Her `Create`'i ayrı `try..finally` ile korumalı sıraya koymak ya da tek tek sarıp `FreeAndNil` kullanmak.

### R-A-7 (şüpheli) · VDbSync kilit defteri: handle kapanınca temizlenmezse sahte "kilit bende"
**Kanıt:** `VDbSync.pas:115-159` (GLockSlots), `VDbSync.pas:286-341` (Release / TryAcquireWin)

- Defter (GLockSlots, sabit 64 slot) handle tabanlıdır; `CloseLockSlot` yalnızca `VDbPageStore.Close` içinde (`VDbPageStore.pas:521-523` civarı) çağrılır. Kendi handle'ını kapatmayan bir kullanıcı için defter girdisi kalır ve sonraki oturum **sahte "kilit zaten elimde"** algılayabilir → iki yazarın aynı anda girmesi.
- Bellek sızıntısı **değildir** (dizi sabit boyutlu); eşzamanlılık bozulması riskidir. Kod tabanında `CloseLockSlot` çağrısı disiplinli göründüğü için derece **ORTA/şüpheli**.

**Öneri:** Handle kapanışını otomatik doğrulayan/gözetleyen bir temizlik (veya defterde handle sahibi süreç doğrulaması).

---

## DÜŞÜK

### R-A-8 · ReadBytesAt: raise yolunda kendi aldığı paylaşımlı kilit bırakılmıyor
**Kanıt:** `VDbPageStore.pas:2030-2075`

- `selfShared := True` (satır 2060) iken ikinci hata oluşursa satır 2064-2068'deki `raise`'e ulaşılır; `VDbUnlockStream` (satır 2070-2074) **çağrılmaz**.
- `VDbSync.pas:32-38` yorumuna göre kitaplık, kapanışta iplik yer tutucusunu kendisi temizler → kalıcı sızıntı değil, yalnızca kilit o deneme boyunca takılır. Bu nedenle DÜŞÜK (şüpheli derece: çok süreçli senaryoda gecikme yaratabilir).

### R-A-9 · Update: geri koyma başarısızsa kayıt kaybı
**Kanıt:** `VDbPageHeap.pas:1387-1439`, özellikle `1426-1436`

- `DeleteAt` + `InsertRaw` sıralamasında ikinci `InsertRaw` başarısızsa eski değer geri konur (satır 1430) ama **geri koyma da** başarısızsa (satır 1433-1435) kayıt tamamen kaybolur ve `Result = False` döner. Kod yorumu (satır 1422) "veri kaybi yok" der; bu yalnızca geri koyma başarılıysa doğrudur.
- Not: eski tasma zinciri `DeleteAt` içinde `FreeOverflow` ile serbest bırakılır (satır 902-903) — burada alan sızıntısı **yoktur**.

### R-A-10 · VerifyFreeList / DirtyPages: satır başına `SetLength(n+1)` → O(n²) kopyalama
**Kanıt:** `VDbPageStore.pas:2577`, `VDbPageStore.pas:2766` civarı

- Her doğrulama/çıkış adımında dizi birer birer büyütülür; sayfa sayısı N için O(N²) bayt kopyalama. Büyük veritabanında çıkış/yazma süresini uzatır. Bellek sızıntısı değil, churn.

### R-A-11 · Constructor yarıda kalırsa destructor başlatılmamış kilit ile karşılaşır
**Kanıt:** `VDbPageStore.pas:651-686` (constructor), ilgili `destructor Destroy`

- Constructor içinde exception olursa (ör. dosya açma hatası) sonraki `InitCriticalSection` çağrılmamış olabilir; `Destroy` yine de `DoneCriticalSection` çağırır → **yarım kalmış nesne** durumunda tanımsız davranış. FPC'de `TryEnterCriticalSection`'in False döndüğü senaryo (satır 38-45 yorumu) ile birleşirse kilit beklenenden önce bırakılabilir.
- Gerçekleşme olasılığı düşük; DÜŞÜK.

### R-A-12 · Şifreli okuma/yazmada sayfa başına TBytes tahsisi
**Kanıt:** `VDbPageStore.pas:2077-2132` (`ReadPageAt`/`WritePageAt`)

- Şifreli yolda her sayfa için `env` + `plain` TBytes tahsis edilip bırakılır → GC olmayan FPC'de sürekli heap churn (4KB × 2 × sayfa başına). Yoğun taramalarda performans etkisi; sızıntı değil.

---

## BİLGİ / temiz görünen yerler

- **VDbCrc32.pas:** Kaynak yaşam döngüsü bulgusu yok (yalnızca saf hesaplama).
- **VDbChangeLog.pas:1007-1106** (`AppendForeignGroup`): `TMemoryStream` `try..finally` ile serbest bırakılır; `EndGroup` hata yolunda segment geri sarılır — temiz.
- **VDbExecutor.pas:** Hedefli taramada `TStringList`/`TFileStream`/`TDictionary` kullanımı genelde `try..finally` ile korumalı (ör. `VDbExecutor.pas:1600-1633`, `21142-21151`). Devasa dosya (21.569 satır) olduğu için yalnızca hedefli tarama yapıldı; tüm Create/Free çiftleri doğrulanmış değildir.
- **VDbTable.pas:** Destructor (`VDbTable.pas:5219-5244`) tüm koleksiyonları serbest bırakır; savepoint kopyaları (`FSnapTables` vb., `VDbTable.pas:6231-6288`) kapanışta temizlenir. Savepoint başına tam tablo kopyası tasarım gereğidir; sınırsız savepoint = sınırsız bellek (kullanıcı kontrolünde, bilgi).
- **Tasarım gereği büyümeler:** Bellekte satır dizileri, `FPageKeys`/`FPageType` amortize büyümesi (+64 adım, `VDbPageHeap.pas:397-432`) sızıntı değil, bilinçli tasarımdır.

---

## Kapsam ve Sınırlılıklar

- Derleme/çalıştırma yapılmadığından hiçbir bulgu çalışma zamanında doğrulanmamıştır; tümü statik okuma kanıtına dayanır.
- `VDbExecutor.pas` (21.569 satır) ve `VDbTable.pas` (12.331 satır) yalnızca hedefli örüntü taraması ile incelenmiştir (TStringList/TFileStream/TDictionary Create-Free, SetLength kalıpları). Bu iki dosyada gözden kaçmış sızıntı olasılığı vardır.
- "Şüpheli" işaretli bulgular (R-A-7, R-A-8) çalışma zamanı senaryosuna bağlıdır; kod okumasıyla kesinleşmemiştir.


---

# EK-B — Eszamanlilik, Kilitleme ve Yaris Kosullari

# Eşzamanlılık, Kilitleme ve Yarış Koşulları Denetimi — Rapor B

**Hedef:** `D:\veritabani` (dal v3, FPC 3.2.4 Delphi modu, i386-win32) Pascal veritabanı motoru
**Kapsam:** Yalnızca eşzamanlılık / kilitleme / yarış koşulları ekseni
**Tarih:** 2026-11-06
**Yöntem:** Salt okunur statik inceleme. Hiçbir dosya değiştirilmedi, derleme/çalıştırma yapılmadı. Her bulgu dosya:satır kanıtıyla verilir; erişim zinciri tam doğrulanamayan iddialar **(şüpheli)** olarak işaretlenmiştir.

**Şiddet sıralaması:** KRİTİK > YÜKSEK > ORTA > DÜŞÜK > BİLGİ

---

## Özet Tablo

| No | Şiddet | Başlık |
|----|--------|--------|
| B-01 | KRİTİK | İç içe/paralel tarama paylaşılan tarama durumunu bozar (FStream*/FScan*/FSnapMap) |
| B-02 | KRİTİK | Tembel indeks yapıları paylaşımlı okuma kilidi altında mutate ediliyor |
| B-03 | YÜKSEK | AbortBatch koşulsuz `EndDeferRefresh` → FDeferCount çift düşürme |
| B-04 | YÜKSEK | BeginBatch istisna yolunda FDeferCount sızıntısı + TWriteSet iade edilmez |
| B-05 | YÜKSEK | `TryAcquireWriteHold` process-içi paylaşımlı derinlik sayacı (FHoldDepth) |
| B-06 | YÜKSEK | `VerifyNoConflict` FAlien zamanlama penceresi (kayıp güncelleme) |
| B-07 | YÜKSEK | `ReadBytesAt` geçici paylaşımlı kilidi hata yolunda serbest bırakmıyor |
| B-08 | YÜKSEK | Kilit defteri handle-yeniden-kullanım hayalet kilidi (GLockSlots) |
| B-09 | ORTA | `LockBookInit` DCL yarışı (çift `InitCriticalSection`) |
| B-10 | ORTA | SH→EX yükseltme başarısızsa mevcut paylaşımlı kilit sessizce kaybedilir |
| B-11 | ORTA | `ReleaseWrite/ReleaseDataWrite` 5 sn FWriteCs altında busy-retry + sessiz kilit kaybı |
| B-12 | ORTA | Busy-wait kilit denemeleri FWriteCs içinde (tüm process-içi thread'leri bloklar) |
| B-13 | ORTA | Store-bazlı derinlik sayaçları thread/oturum bazlı değil |
| B-14 | ORTA | `FT.Backend.BeginBatch` + `FT.AbortBatch` karışık eşleşmesi (4 site) |
| B-15 | ORTA | Ham API'de oturum kimliği 0 → tüm batch'ler tek TWriteSet'i paylaşır (şüpheli) |
| B-16 | ORTA | Bayrak/önbellek alanları yalnızca çağıran kilit disiplinine dayanıyor (şüpheli) |
| B-17 | ORTA | `ExclusiveAccess` çalışma anında değiştirilebilir; MREW Lock/Unlock çiftini bozabilir (şüpheli) |
| B-18 | DÜŞÜK | `AwaitDurable` istisnası `FSyncBusy`'yi temizlemiyor (şüpheli) |
| B-19 | BİLGİ | Unix yolunda kilit defteri tutulmuyor (platform farkı) |
| B-20 | BİLGİ | `CheckRowWritable` TOCTOU penceresi (yalnız ExclusiveAccess modunda açık) |

**Toplam: 20 bulgu (2 KRİTİK, 6 YÜKSEK, 9 ORTA, 1 DÜŞÜK, 2 BİLGİ)**

---

## KRİTİK

### B-01 — İç içe / paralel tarama, backend'e özel paylaşılan tarama durumunu bozar

**Mekanizma:** `TVdbBackendV3` içindeki tarama durumu (`FStreamCb`, `FStreamUser`, `FStreamAbort`, `FStreamFilter`: `VDbBackendV3.pas:337-343`; `FScanKeys/FScanVals/FScanN`: `VDbBackendV3.pas:319-320`; `FSnapMap`: `VDbBackendV3.pas:273`) backend nesnesine tekildir, yani **tüm oturumlar ve tüm sorgular ortak kullanır**.

**Alt sorun A — alanlar kilit dışına yazılmaktadır:**
`ScanRawIterAll` içinde `FStreamCb := Cb; FStreamUser := User; FStreamAbort := False; FStreamFilter := TableFilter;` atamaları `FEngCs.Enter`'dan **önce** yapılmaktadır (`VDbBackendV3.pas:2562-2568`). `ScanRawIterAllPaged` için aynı desen (`VDbBackendV3.pas:2642-2646`). İki thread aynı anda tarama başlatırsa biri diğerinin callback/User değerini ezer; yanlış callback yanlış tipte `User` ile çağrılır (tip karışıklığı → bellek bozulması riski).

**Alt sorun B — iç içe tarama (yeniden giriş) tüm tarama durumunu yok eder:**
Tarama callback'leri satır bazlı SQL değerlendirme yapıyor: streaming SELECT `VdbStreamSelCb` (`VDbExecutor.pas:13049`, planlama `VDbExecutor.pas:13921-13934`) satır başına `RowMatches`/`EvalExpr` çağırır (`VDbExecutor.pas:13138-13179`). Correlated alt sorgu (`IsCorrelatedSel`, `VDbExecutor.pas:2823`; `SubResult` → satır başına yeniden `ExecSelect`, `VDbExecutor.pas:2943-2985`) bu değerlendirme içinde **iç taramayı** tetikler. `TVdbGate` aynı thread için yeniden girişli (derinlik 2) olduğundan iç tarama `FEngCs`'ten içeri girer ve:

- dış taramanın `FStreamCb/FStreamUser/FStreamAbort/FStreamFilter` değerlerini sıfırlar/yeniden yazar (`VDbBackendV3.pas:2562-2565`, `2642-2645`),
- `FSnapMap`'i `FreeAndNil` ile serbest bırakır (`VDbBackendV3.pas:2611`; ayrıca `2326`) — dış taramanın `for pair in FSnapMap` döngüsü (`VDbBackendV3.pas:2576-2577`) serbest bırakılmış nesne üzerinde yürümeye devam eder → **use-after-free / AV riski**; satır bazlı `FSnapMap.ContainsKey` okuması (`VDbBackendV3.pas:2533`) da artık çöktürülmüş nesneye bakar,
- `FScanKeys/FScanVals/FScanN` tamponlarını sıfırlar (`VDbBackendV3.pas:2292-2295`, `2359-2364`, `2480-2493`) → dış taramanın topladığı satırlar sessizce kaybolur veya iç taramanın satırları dışarı sızar.

Etkilenen tüm tarama kullanıcıları: `VDbExecutor.pas:5506` (count), `9127` (aggregate), `10381` (join), `11016` (group), `13341` (distinct), `13921-13934` (select), `14061`/`14164` (order). Bunların hepsinin callback'leri satır değerlendirme (ve dolayısıyla correlated alt sorgu) çağırabilir.

**Etki:** Yanlış sorgu sonucu (sessiz satır kaybı/eklenmesi), yanlış callback çağrısı, kullan-ve-serbest-bırak bellek erişimi → çökme. Hem tek thread iç içe sorgu, hem iki paralel sorgu tetikler.
**Öneri:** Tarama durumunu stack'e alın (her `ScanRawIterAll*` çağrısı yerel bir kayıt üzerinde çalışsın; `FEngCs` altında tek bir yuva değil, tekrar girişli kayıt listesi), alan yazımını `FEngCs` içine alın; `FSnapMap` sahipliğini tarama kaydına taşıyıp kendi ömrü boyunca serbest bırakın.

---

### B-02 — Tembel indeks yapıları paylaşımlı okuma kilidi (LockRead) altında mutate ediliyor

**Mekanizma:** `TVTableDb` indeksleri tembel kurar. `TryGetMemIndex` (`VDbTable.pas:9696-9778`) yalnızca **okumakla kalmaz**, şu ortak yapıları **yazar**:

- `FlushIdxPending(k)` çağrısı — bekleyen indeks işlemlerini uygular (`VDbTable.pas:9727-9728`); kendisi `FIdxPending`/`FIdxDirty`/`FSkipIdx`/`FMemIdx`'i değiştirir (`VDbTable.pas:9504-9580`),
- `FMemIdx.AddOrSetValue` (`VDbTable.pas:9742`, `9770`, ayrıca `BuildOneIndex` içinden `8170`),
- `BuildOneIndex(t, j)` — tam indeks kurulumu (`VDbTable.pas:9750`),
- `BuildPkIdx` + `FPkIdx/FPkIdxDirty` yazımı (`VDbTable.pas:9769-9771`),
- `FHasIdxWorkTid := 0` (`VDbTable.pas:9773`).

Aynı desen `TryGetIdxSource`'ta da var (`VDbTable.pas:9622-9695`, `9644-9663`).

Bu fonksiyonlar **SELECT yolundan** çağrılıyor: `TVSql.TryIndexSelect` (`VDbSql.pas:1653`, çağrılar `VDbSql.pas:1731`, `1764`), planlama/join hazırlığı (`VDbExecutor.pas:4452`, `4484`, `5620`, `7429`, `9451`, `9458`, `10355`), `CandidatePks` (`VDbTable.pas:10694`), `FindConflictPk` (`VDbTable.pas:11823`).

**Kilit boşluğu:** SQL katmanında tümü-SELECT sorguları `FT.LockRead` ile çalışır (`VDbSql.pas:3157`, `3184`, `3315`, `3416`) — yani **paralel okuyucular** kasıtlı olarak eşzamanlıdır. `TMultiReadExclusiveWriteSynchronizer` okuyucuları birbirinden ayırmaz. `TVTableDb` içinde bu yapıları koruyan bir kritik bölüm **yoktur** (`FLock` MREW: `VDbTable.pas:320`, `FRowLockCs` yalnız satır kilitleri için: `VDbTable.pas:434`, `1161-1225`). `TDictionary`/`TList` eşzamanlı yazıma dayanıklı değildir.

**Gerçek çok-thread kullanımı:** Sunucu her bağlantıya ayrı `TVSql` verir ama **tek ortak** `TVTableDb` kullanır (`VDbSqlServer.pas:86` `Ftb: TVTableDb`; `169` `TVSql.Create(AServer.Ftb)`; `415` `Ftb := TVTableDb.CreateBackend(FBe)`). İki bağlantının paralel SELECT'i aynı `FMemIdx`/`FSkipIdx`/`FIdxDirty`/`FPkIdx` üzerinde yazışır.

**Etki:** TDictionary iç yapısının bozulması (bucket/rehash yarışı) → çökme, yanlış indeks girdisi → yanlış sorgu sonucu, çift indeks kurulumu/çift pending uygulama. Yarış yazma-içi değil **okuyucu-okuyucu** olduğundan mevcut yazma kilidi bunu engellemez.
**Öneri:** Lazy indeks kurulumu/flush için ayrı bir `TCriticalSection` (veya `FHasIdxWorkTid` önbelleğindeki gibi "önce kilit yaz" deseni) ekleyin; ya da lazy build sadece yazma kilidi altında yapılsın, okuyucular yalnızca hazır sonucu okuyabilsin (double-checked + immutable snapshot dağıtımı).

---

## YÜKSEK

### B-03 — `AbortBatch` koşulsuz `EndDeferRefresh` çağırıyor; `FDeferCount` çift düşürülür

`TVdbBackendV3.BeginBatch` içinde `BeginDeferRefresh` yalnızca `not gotReserve` ise çağrılır (`VDbBackendV3.pas:2864-2872`). Buna karşılık `AbortBatch` `EndDeferRefresh`'i **koşulsuz** çağırır (`VDbBackendV3.pas:3049-3076`, çağrı `3073`). `FDeferCount` store-bazlı **paylaşımlı** bir derinlik sayacıdır (`VDbPageStore.pas`).

**Senaryo:** Rezervasyonlu (optimistic) bir batch, commit hata verip `AbortBatch` ile kapanırsa — ya da rezervasyonsuz bir oturumun `AbortBatch`'i başka bir oturumun açık `BeginDeferRefresh` dengesine denk gelirse — sayaç defalarca düşer. Sayaç 0'ın altına inince `RefreshIfStale` (bayat tazeleme) davranışını bozar; ilgili oturumun before-image/snapshot tutarlılığı (B-06 ile birleşince) kırılır.
**Öneri:** `EndDeferRefresh`'i yalnızca bu batch'in gerçekten `BeginDeferRefresh` yaptığını işaretleyen bayrakla çağırın (batch yerel `gotDefer: Boolean`).

### B-04 — `BeginBatch` istisna yolunda `FDeferCount` sızar, TWriteSet havuza iade edilmez

`TVdbBackendV3.BeginBatch` (`VDbBackendV3.pas:2837-2884`) içinde `FSets.AddOrSetValue` sonrası bir istisna olursa (ör. rezervasyon/kayıt hatası) except yolu `EndDeferRefresh` çağırmıyor ve tahsis edilen `TWriteSet`'i `FSetPool`'a iade etmiyor. Sonuç: `FDeferCount` kalıcı artar → tazeleme ertelenmesi kalıcı devre dışı kalır → bayat önbellekle yazma riski; ayrıca her sızıntı bir `TWriteSet` nesnesi biriktirir.
**Öneri:** `try/except` içinde her tahsis edilen kaynağı geri veren tek bir temizlik bloğu.

### B-05 — `TryAcquireWriteHold` process-içi paylaşımlı `FHoldDepth` sayacına bakıyor

`TVDbPageStore.TryAcquireWriteHold` (`VDbPageStore.pas:1598-1636`) `FHoldDepth > 0` ise **aynı process'teki başka oturuma da** `True` döner. Derinlik sayacı store-bazlıdır; oturum/thread bazlı sahiplik yoktur. Böylece process-içi eşzamanlı iki oturum da kendini "seri yazma tutucu" (NeedBefore=False, before-image gerekmez) sanır; optimist yazma (before-image `VerifyNoConflict`) koruması process-içinde anlamını yitirir. Rezervasyonun "yazarlar sırayla girer" garantisi yalnız **processler arası** geçerlidir.
**Öneri:** Hold'ü oturum kimliğiyle sahiplendirin (`FHeldBySession: Cardinal`); yalnız sahibine `True` dönün.

### B-06 — `VerifyNoConflict` FAlien zamanlama penceresi (kayıp güncelleme)

`TVdbBackendV3.VerifyNoConflict` (`VDbBackendV3.pas:1807-1860`) yabancı commit'i (FAlien) yalnızca `S.Before`'da **olmayan** anahtar için denetler (`VDbBackendV3.pas:1822-1833`). Before-image, `NoteBefore` ile (`VDbBackendV3.pas:1784-1805`) yazmadan hemen önce alınıyor. Bir yabancı commit before-image alındı**ktan sonra** ilgili anahtarı değiştirirse hem before-image artık o anahtarı kapsamaz hem FAlien denetimi atlanır → çakışma bildirilmez.

**Etki:** "İlk commit kazanır" kuralı zamana bağlı olarak iki farklı biçimde uygulanır; kayıp güncelleme (lost update) penceresi açık kalır. Optimist eşzamanlılığın temel garantisi tutarsız.
**Öneri:** Before-image'de olmayan anahtarlar için FAlien denetimini yazma anına (commit zaman damgası karşılaştırmasıyla) sabitleyin; "son yazan kazanır/ilk kazanır" kuralını tek yerde, atomik biçimde uygulayın.

### B-07 — `ReadBytesAt` geçici paylaşımlı kilidi hata/yükseltme yolunda serbest bırakmıyor

`TVDbPageStore.ReadBytesAt` (`VDbPageStore.pas:2030-2075`) kilit ihlalinde `TakeSharedLock` ile geçici (`selfShared`) paylaşımlı kilit alıyor; ancak hata/yükseltme (SH→EX) başarısızlık yollarında `raise` öncesi `selfShared` kontrolüyle kilidi **serbest bırakmıyor**.

**Zincir:** Sızan OS kilidi dosya handle'ı kapanınca düşer, ama `VDbSync` kilit defterinde (`GLockSlots`) `Held=True` olarak kalır (`VDbSync.pas:156-275`). Handle değeri yeniden kullanıldığında (`VDbLockStream`, `VDbSync.pas:279-319` civarı Windows yolu) defter "zaten kilitli" der ve **OS'e hiç dokunmadan `True` döner** → kilit yokken kilitli sanılır; tersine, gerçek sahibi `VDbUnlockStream` ile başkasının kilidini açabilir.
**Öneri:** `selfShared` için `try/finally` ile her çıkışta unlock; defterdeki `Held` kaydını OS kilidiyle her zaman senkron tutan tek bir sahiplik nesnesi (handle + nesne ömrü birlikte).

### B-08 — Kilit defteri handle-yeniden-kullanım hayalet kilidi (GLockSlots)

`LockBookInit`/defter (`VDbSync.pas:130-275`) kilit kayıtlarını **handle değeri** indeksliyor. B-07'deki sızıntı ya da kapatılan/çökertilmiş bir oturumdan kalan `Held=True` kaydı, aynı handle değerini yeniden alan yeni bir dosya nesnesiyle eşleşir. `VDbLockStream` defterde `Held` görürse OS kilidine başvurmadan başarılı döner; `VDbUnlockStream` ise başkasının (yeni nesnenin) kilidini açar.

**Etki:** Eşzamanlı iki writer aynı dosya üzerinde karşılıklı korumasız yazabilir (veri bozulması), veya yanlışlıkla açılan kilit yüzünden beklenen koruma yok olur. Windows yolu birincil hedef olduğundan (bkz. B-19) etkin.
**Öneri:** Defter anahtarını handle + nesne nesil/UUID yapın; ya da defteri tamamen kaldırıp OS kilidi sonuçlarına güvenin.

---

## ORTA

### B-09 — `LockBookInit` çift kontrol kilidi (DCL) yarışı

`GLockInit` kontrolü kilitsiz yapılır (`VDbSync.pas:130-135`). İlk kilit çağrısını aynı anda yapan iki thread `InitCriticalSection(GLockCs)`'i **iki kez** çağırabilir. Zaten kilitli bir kritik bölümü yeniden başlatmak durumu bozar (kilit sayacı/sahipliği kaybı → kilitlenme veya korumasız erişim).
**Öneri:** `InitCriticalSection`'i ünite başlangıcında tek seferde (veya `InterlockedCompareExchange` bayrağıyla) yapın.

### B-10 — SH→EX yükseltme başarısızsa mevcut paylaşımlı kilit kaybedilir

`VDbSync.pas:248-275`: paylaşımlı kilidi tutan bir akış exclusive yükseltme denemesinde başarısız olursa (başka process EX kilidi almışsa) yol mevcut SH kilidini bırakır/ezberden düşürür ve hata döner; çağıran taraf hâlâ paylaşımlı kilidi tuttuğunu sanabilir. Eşzamanlı iki process "yükseltme denemesi" yarışında biri sessizce korumasız kalır.
**Öneri:** Yükseltme başarısızsa mevcut SH'yi koruyup kesinlikle bırakın; çağıranı durumdan haberdar eden ayrı sonuç kodu.

### B-11 — `ReleaseWrite/ReleaseDataWrite` kilit altında 5 sn busy-retry + sessiz kilit kaybı

`TVDbPageStore.ReleaseWrite` (`VDbPageStore.pas:1506-1516`) ve `ReleaseDataWrite` (`VDbPageStore.pas:1711-1721`) paylaşıma geri dönüşü **FWriteCs tutulurken** 5 saniye boyunca tekrar tekrar dener. Bu süre boyunca store'daki **tüm** işlemler (diğer thread'lerin de FWriteCs alması gerektiği için) bloklanır. Deneme başarısızsa `FLockedShared` sessizce `False` kalır: okuyucu kilit sessizce kaybolur, sonraki okuyucular OS kilidi beklentisiyle korumasız okur.
**Öneri:** Retry'yi kilit altında değil, kısa kilitleme/aralıklı denemeyle; başarısızlıkta kullanıcıya hatayla bildirin (sessiz düşürme değil).

### B-12 — Busy-wait kilit denemeleri FWriteCs içinde (canlılık)

`LockExclusive`/`LockReserve` (`VDbPageStore.pas:919-982`) ve `TakeSharedLock` (`VDbPageStore.pas:1533-1571`) kilit bekleme döngülerini **FWriteCs içinde** yürütür. Başka bir process dosya kilidini elinde tuttuğunda, bu process'teki bağımsız tüm thread'ler FWriteCs yüzünden `FBusyMs` (20 sn) kadar bloklanır. Bu bir deadlock değil ama tüm sunucuyu kilitleyen bir canlılık darboğazıdır; B-11 ile birleşince pencere büyür.
**Öneri:** Bekleme döngüsünü FWriteCs dışında yapın (yalnız kilit defterine dokunan kısa kritik bölümler).

### B-13 — Derinlik sayaçları store-bazlı, thread/oturum bazlı değil

`FReadDepth/FWriteDepth/FHoldDepth/FDeferCount` (`VDbPageStore.pas`) tek store nesnesi üzerinde ortaktır. İki thread aynı store'a (tek `TVTableDb`/backend paylaşımı — bkz. B-02'deki `VDbSqlServer.pas:169,415`) aynı anda girerse biri diğerinin paylaşımlı kilidini yükseltebilir/düşürebilir; `ReleaseWrite` herhangi bir thread'in derinliğini sıfırlayabilir. Yükseltme/düşürme eşleşmesi çağrı yığınına değil nesneye bağlı olduğu için iç içe kullanım bozulur.
**Öneri:** Derinlikleri thread-local veya oturum sahiplikli tutun.

### B-14 — `FT.Backend.BeginBatch` + `FT.AbortBatch` karışık eşleşmesi (4 site)

`VDbExecutor.pas` içinde dört yerde backend-seviyesi `BeginBatch/CommitBatch` kullanılırken hata yolunda **tablo-seviyesi** `FT.AbortBatch` çağrılır:

| Site | Begin | Commit | Abort |
|------|-------|--------|-------|
| Çok satırlı INSERT/UPSERT | `15637` | `15771` | `15773` |
| INSERT ... SELECT | `16204` | `16213` | `16215` |
| UPDATE batch | `17970` | `18023` | `18028` |
| DELETE batch | `18214` | `18229` | `18234` |

`TVTableDb.BeginBatch` (`VDbTable.pas:6384-6393`) sema yedeği alır; `FT.AbortBatch` (`VDbTable.pas:6410-6436`) ise buna karşılık **ağır yan etkiler** uygular: `StopConcBuilders` (başka oturumların süren `CREATE INDEX CONCURRENTLY` inşalarını iptal eder — **oturumlar arası girişim**), `FDeferredRows.Clear`, `RestoreSchemaSnapshot` (kendi batch'i olmadığı için bayat/eksik yedek) ve **tüm tabloların tüm indekslerinin veriden yeniden kurulumu** (`6432-6435`). Kendi `BeginBatch`'i olmayan bu dört yol, açık bir işlem beklentisi olmadan başka oturumların işini bozabilir; ayrıca `FT.Backend.CommitBatch` `FlushAutoIncCache`/`SaveSchema` yapmadığından (B-16 ile ilgili) kimlik sayacı kalıcılığı da bu yolda atlanır.
**Öneri:** Dört sitede de ya `FT.BeginBatch/FT.CommitBatch/FT.AbortBatch` üçlüsünü kullanın ya da `AbortBatch`'i "backend-only" bir varyanta bölün.

### B-15 — Ham API'de oturum kimliği 0: tüm batch'ler tek TWriteSet'i paylaşır (şüpheli)

Backend yazma kümesi seçimi `FBatchSetSid = VdbBackendSessionId` denetimine dayanır (`VDbBackendV3.pas:1479-1499`, `1533-1539`). `VdbBackendSessionId` (`VDbBackendApi.pas:362-370`) threadvar `GVdbTxnSession`'dan gelir (`VDbCore.pas:853-864`). SQL katmanı bunu bağlantı başına benzersiz atar (`VDbSql.pas:242` `FSessionId := Cardinal(PtrUInt(Self))`, `260`), ancak **ham API** (doğrudan backend'i kullanan gömücü) `VDbSetWriteSession` çağırmazsa tüm oturumlar `0` olur → aynı `TWriteSet` ortak kullanılır, `VerifyNoConflict`/before-image ayrımı çöker. Kullanım zinciri gömücüye bağlı olduğundan **(şüpheli)**.
**Öneri:** Backend, session=0 ile eşzamanlı batch açılışını reddetsin veya otomatik benzersiz oturum atasın.

### B-16 — Bayrak/önbellek alanları yalnızca çağıranın kilit disiplinine dayanıyor (şüpheli)

`FBatchTableCached`, `FPrefixCacheName/FPrefixCacheVal`, `FBatchHasPkIdx`, `FBatchHasIdentity`, `FBatchHasGenerated`, `FBatchTableDef/FBatchHashPrefix`, `FHasIdxWorkTid/FHasIdxWorkNIdx/FHasIdxWorkRes` (`VDbTable.pas:357-395`) hiçbir iç kilit ile korunmaz; `Insert` gövdesi (`VDbTable.pas:10378-10475`) ve `HasIdxWork` (`VDbTable.pas:7771-7786`) bu alanları doğrudan yazar. Koruma tamamen çağıranın `FT.Lock` (yazma MREW) tutmasına bağlıdır — SQL katmanı bunu sağlar (`VDbSql.pas:3212-3217`, `ExecAllInner` sözleşmesi `3224-3226`).

Ancak doğrudan API kullanıcıları kilit almaz: `VDbImportJson` (`VDbJson.pas:2543-2642` — `BeginBatch/Insert/CommitBatch/AbortBatch`) GUI'den çağrılır (`yonetim\hadmain.pas:2461`), `BatchInsert` araçtan çağrılır (`yonetim\hadtools.pas:210`, `218`). Bu araçlar muhtemelen tek iş parçacıklıdır; ancak API sözleşmesi bunu zorlamaz ve aynı `TVTableDb`'ye SQL trafiği akıyorsa bu alanlarda yarış doğar (ör. `FPrefixCacheVal` yarım yazılıp başka tablonunki okunur → yanlış hash öneki → yanlış PK anahtarı). **(şüpheli)** — araçların çalışma biçimi doğrulanmadı.
**Öneri:** `Insert`/`HasIdxWork` girişinde idempotent `Lock` (veya bu alanları thread-local yapın); doğrudan API'ye "kilit senin sorumluluğunda" notunu sözleşme olarak yazın.

### B-17 — `ExclusiveAccess` çalışma anında değiştirilebilir; MREW Lock/Unlock çiftini bozabilir (şüpheli)

`TVTableDb.Lock/Unlock/LockRead/UnlockRead` (`VDbTable.pas:5201-5225`) her çağrıda `FKvB.ExclusiveAccess`'e bakar ve mod açıksa MREW'i tamamen atlar. `ExclusiveAccess` düz bir `Boolean` property'dir (`VDbPageStore.pas:183`, `324`), kilitsiz yazılır; backend API'si üzerinden **her an** set edilebilir (`VDbBackendApi.pas:192-194`, `TVdbBackendV3.SetExclusiveAccess` `VDbBackendV3.pas:3432-3435`). `Lock` ile `Unlock` arasında mod değişirse: Lock alan thread Unlock'da `EndWrite`'ı atlar → **yazma kilidi kalıcı olarak açık kalır** (tüm MREW kullanıcıları kilitlenir); tersi olursa `EndWrite`'sız `EndWrite` çağrılır → MREW durum bozulması. Repo içinde runtime atama bulunamadı (yalnız gömücü API'si); bu yüzden **(şüpheli)** — ancak API yüzeyi açıktır ve `FExclusiveAccess` okumaları barrier'sızdır (thread'ler eski değeri görebilir).
**Öneri:** Modu yalnızca kurulum sırasında değiştirilebilir yapın (setter hata versin), ya da Lock/Unlock eşleşmesini kendi yerel bayrağınızla yapın.

---

## DÜŞÜK

### B-18 — `AwaitDurable` istisnası `FSyncBusy`'yi temizlemiyor (şüpheli)

`TVdbPageEngine.AwaitDurable` (`VDbPageEngine.pas:866-964`) grup fsync sonrası `FStore.SetDurableLsn` çağrısı (`VDbPageEngine.pas:946`) istisna atarsa `FSyncBusy := False` atlanır ve `FSyncEvt` bekleyenleri sonsuz/uçsuz beklemeye girebilir (20 ms timeout'lu döngü olduğu için "sonsuz" değil ama sürekli döngü). `SetDurableLsn`'nin istisna atması olağan dışıdır; bu yüzden DÜŞÜK **(şüpheli)**.
**Öneri:** `try/finally` ile `FSyncBusy` temizliği.

---

## BİLGİ

### B-19 — Unix yolunda kilit defteri tutulmuyor

`VDbLockStream/VDbUnlockStream` Windows yolunda deftere (`GLockSlots`) yazar, Unix `flock` yolunda yazmaz (`VDbSync.pas:279-319`). `VDbLockHeld` Unix'te her zaman `False` döner; B-07/B-08'in handle-yeniden-kullanım etkisi yalnız Windows'ta doğar. Platformlar arası davranış farkı bilinçli değilse tutarlılık hedefi gözetilmeli.

### B-20 — `CheckRowWritable` TOCTOU penceresi (yalnız ExclusiveAccess modunda)

`TVTableDb.CheckRowWritable` (`VDbTable.pas:1214-1225`) denetle-sonra-yaz kalıbıdır; `LockRow` (`1161-1177`) ile satır yazımı arasında atomiklik yoktur. Normal modda MREW yazma kilidi bu pencereyi kapatır (yazan yazma kilidini tek başına tutar). Ancak `ExclusiveAccess` modunda (B-17) MREW atlandığından pencere açılır.

---

## İncelenip Bulgu Olmayanlar (Doğrulandı)

1. **AB-BA kilit sırası ihlali kanıtlanamadı.** `BeginBatch` FEngCs → (FWriteCs + gen rezervasyonu), `CommitBatch` rezervasyon → FEngCs → AcquireDataWrite sırasında; `TryAcquireWriteHold` non-bloklu; Flush/BeginWrite kilitleri FEngCs'ten önce. `RefreshIfStaleForce` FWriteCs içindeyken `FOnRefreshed` (`VDbPageEngine.StoreRefreshed`, `VDbPageEngine.pas:343-467`) çağrır, ancak `StoreRefreshed` **FEngCs almaz** → kilit sırası temiz.
2. **WAL grup fsync iddiası geçerli.** WAL tek dosyadır ve `fmShareDenyNone` ile açılır (`VDbPageWal.pas:428-461`); `AwaitDurable`'ın grup fsync tasarımı (`VDbPageEngine.pas:866-964`) bu yapıyla tutarlı.
3. **`VDbLockGenReserve` ayrı handle kullanır** (`FGenStream`, `VDbPageStore.pas:1829` — `FPath+'.gen'`), `VDbLockStream`'in tüm-dosya kilidiyle ($FFFFFFFF,$FFFFFFFF) dosya-bazında kilit çakışması yok.
4. **Satır kilidi tablosu kilit korumalı.** `FRowLocks` tüm erişimlerde `FRowLockCs` ile korunur (`VDbTable.pas:1161-1225`).
5. **`FHasIdxWorkTid := 0` yazımı (B-02'den ayrı)** okuma yolunda (`VDbTable.pas:9773`) tek başına benign'dir (aynı değerin idempotent yazımı, x86 hizalı Word); asıl sorun B-02'deki sözlük yarışıdır.
6. **`VDbExecutor.pas:782` `FSessionId := 0`** başlangıç değeri, `VDbSql.pas:260` ile set edilir — SQL katmanı için sorun değil (yalnız B-15 kapsamına girer).

---

## Kapsam Sınırları

- İnceleme statik kod analizidir; derleme, çalışma zamanı doğrulaması veya stres testi **yapılmamıştır** (kural gereği).
- `(şüpheli)` işaretli maddelerde ya erişim zinciri (çağrı yolu / API kullanımı) tam kapatılamamış ya da istisnanın gerçekleşmesi dış koşula bağlıdır.
- Odak dosyalar: `VDbSync.pas`, `VDbBackendV3.pas`, `VDbPageStore.pas`, `VDbPageEngine.pas`, `VDbTable.pas`; destekleyici olarak `VDbSql.pas`, `VDbExecutor.pas`, `VDbBackendApi.pas`, `VDbCore.pas`, `VDbPageWal.pas`, `VDbJson.pas`, `VDbSqlServer.pas`, `yonetim\hadmain.pas`, `yonetim\hadtools.pas`.


---

# EK-C — Cokme Guvenligi, Dayaniklilik ve Kurtarma

# VDB v3 — Çökme Güvenliği / Dayanıklılık / Kurtarma Denetimi (Eksen C)

- **Kod ağacı:** D:\veritabani (dal v3)
- **Kapsam:** VDbPageWal.pas, VDbPageEngine.pas, VDbChangeLog.pas, VDbPageStore.pas, VDbBackendV3.pas (+ dayanıklılığı etkileyen VDbSync.pas / VDbPage.pas / VDbPageHeap.pas noktaları)
- **Yöntem:** Salt-okunur statik inceleme. Dosya değiştirilmedi, derleme/çalıştırma yapılmadı.
- **Şiddet:** KRİTİK (veri kaybı) > YÜKSEK > ORTA > DÜŞÜK > BİLGİ
- **Not:** "Şüpheli" etiketi, kod okumasıyla doğrulanan ama kilit/çağrı grafiği gibi çalışma-anı koşullarına bağlı senaryolarda kesinleştirilemeyen maddeleri işaretler.

---

## ÖZET TABLO

| # | Şiddet | Başlık |
|---|--------|--------|
| C-1 | KRİTİK | Checkpoint/Truncate, veri dosyasına hiç yazılmamış onaylı sayfaları WAL'den budar (çok süreçli veri kaybı) |
| C-2 | KRİTİK | `.gen` durabil LSN bayat kalır (VACUUM/RESTORE/REKEY/yeniden yaratma) → fsync'siz "durabil" onayı |
| C-3 | KRİTİK | Temiz (view) kurulum + önbellek tahliyesi + MinLSN atlama → eski sayfa sessizce geri gelir |
| C-4 | YÜKSEK | FWrittenLsn Refresh/Recover'da eksik hesaplanır → AwaitDurable asılı kalır / fsync fırtınası |
| C-5 | YÜKSEK | Checkpoint/Compact/Restore/Verify, Truncate'ı süreç-içi kilitsiz çalıştırır; eşzamanlı commit'in kayıtları silinir |
| C-6 | YÜKSEK | CommitNoSync→AwaitDurable arası istisna: uygulanmış ama "başarısız" raporlanan commit |
| C-7 | YÜKSEK | StoreRefreshed korumaları geç çalışır (DropCache/InstallPending, FInTxn ihlalinden önce) |
| C-8 | YÜKSEK | Artımsal tarama koruması (FScanHdrLsn) bellek-içi karşılaştırmadır; dosya başlığını doğrulamaz |
| C-9 | ORTA | WAL başlığı yarım yazılınca veritabanı hiç açılamaz (WAL atılabilir olduğu halde) |
| C-10 | ORTA | TornTail sessizce yutulur; orta-şeritteki bozulma sonraki tüm commit'lerin atlanması demektir |
| C-11 | ORTA | AS OF: taban+WAL kopyası kilitlenmeden alınır; checkpoint ile yarışta tutarsız görüntü |
| C-12 | ORTA | Değişim günlüğü fsync'i WAL fsync'inden önce; "commit zaten durabil" yorumu yanlış |
| C-13 | DÜŞÜK | WAL.Bytes() şifreli modda çerçeveyi yanlış boyutlar; 8 MB eşiği geç ölçülür |
| C-14 | DÜŞÜK | WAL.Commit fsync hatasında tampon temizlenmez → yeniden denemede yinelenen çerçeveler |
| C-15 | DÜŞÜK | Recover MaxCommits kesilmesinde goodPos commit kaydını içermiyor (çift sayım) |
| C-16 | BİLGİ | Sayfa LSN damgası var ama hiç kullanılmıyor (okuma yolunda bayatlık denetimi yok) |

---

## C-1 — KRİTİK: Checkpoint/Truncate, veri dosyasına hiç yazılmamış onaylı sayfaları WAL'den budar

### Mekanizma
1. Commit veri dosyasına **hiçbir şey yazmaz** — kayıtlar yalnız WAL'dedir:
   - `VDbPageEngine.pas:1055-1056` — "WAL commit + fsync: artık durabil. Veritabanı dosyasına bu noktada HİÇBİR ŞEY yazılmaz (checkpoint'e kadar)."
   - `VDbPageEngine.pas:966-1082` (DoCommit): yalnız `FWal.AppendFrame` + `FWal.Commit`.
2. Refresh/tazeleme, başka process'in commit ettiği sayfaları **TEMİZ** (Dirty=False) kurar:
   - `VDbPageStore.pas:2190-2202` (LoadFrame, AImage dalı): "İmaj WAL'de fsync'li olduğu için TEMİZ işaretlenir; **diskteki sürüm yazarın commit'inde güncellenir**."
   - `VDbPageStore.pas:3061-3082` (InstallPage, AViewOnly): mevcut sayfalar temiz kurulur; yalnız `isNew` sayfalar kirli işaretlenir (`3073-3080`).
   - `VDbPageStore.pas:3008-3013` (oturum içi yenileme): "Temiz çerçeve temiz kalır."
   - **Bu varsayım yanlıştır:** madde 1 gereği yazar process commit'te diske hiçbir şey yazmaz; diskteki sürüm yazarın *checkpoint'ine* kadar bayattır.
3. Checkpoint yalnız **kirli** sayfaları yazar, sonra WAL'i tamamen budar:
   - `VDbPageStore.pas:2735-2741` (Flush): `if FFrames[i].Dirty then WritePageAt...`
   - `VDbPageEngine.pas:1119` `FStore.Flush(DoSync)` → `1126` `AwaitDurable(FWal.WrittenLsn)` → `1127` `FWal.Truncate(FStore.LSN)`.
   - `VDbPageWal.pas:943` (`FStream.Size := VDB_PAGE_SIZE`): Truncate **tüm gövdeyi** siler; LSN filtresi yok.
   - `VDbPageEngine.pas:435-445` (StoreRefreshed yorumu): güvenliğin "Flush(True) tüm dosyayı fsync eder" argümanı hatalıdır — Flush fsync eder ama **kirli olmayan çerçeveleri hiç yazmaz**.

### Senaryo (yaygın)
- Process A commit eder (LSN 105, fsync'li WAL; önbellekte kirli, diskte eski imaj) → istemciye "durabil" döner.
- Process B okuma/tazeleme ile sayfayı temiz kurar (`StoreRefreshed → Recover(ApplyRecoveredView)` → `VDbPageEngine.pas:447`, `ApplyRecoveredView` → `InstallPage(..., True)`).
- B kapanır: `VDbPageEngine.pas:612-633` → `Checkpoint(True)`. Flush B'nin temiz çerçevelerini **atlar**; `Truncate(FStore.LSN)` (B'nin LSN'i tazelemede `SetLSN(FWal.WrittenLsn)` ile 105'e çekilmiştir, `VDbPageEngine.pas:449-452`) WAL'i siler.
- A çöker (checkpoint yapmadan): 105'in imajı artık **hiçbir yerde yoktur**. Açılışta kurtarma WAL boş olduğu için (`FHasContent=False`, `VDbPageWal.pas:433`) hiçbir şey uygulamaz. **Onaylı commit kalıcı olarak kaybolur.**
- Aynı durum B kapanmasa da olur: B önbellek baskısıyla temiz çerçeveyi atar (`VDbPageStore.pas:2171-2189` — temiz kurban sessizce düşürülür), sonraki okumada diskteki **eski** imaj gelir (bkz. C-3).

### Ek etki
- `VDbPageEngine.pas:399-404`: `MinLSN = FWal.HeaderLsn` ile taramada `lsn <= MinLSN` kayıtları atlanır (`VDbPageWal.pas:805-811`) — "zaten veritabanı dosyasında" varsayımı da bu bozulmayla çürür; kayıtlar bir daha asla uygulanmaz.
- `VDbPageWal.pas:143-145` (FHeaderLsn yorumu): "Veri dosyası bu LSN'e kadar TAMAMEN günceldir (Truncate öncesinde dosya fsync edilmiştir)" — doğrudur ama yetersizdir: fsync edilen yalnız **kirli** sayfalardır; WAL'deki (başka process'e ait) temiz çerçeveler kapsam dışıdır.

### Not
Tek process'li kullanımda (tek FStore örneği) tüm commit sayfaları ortak önbellekte kirli kaldığı için Flush onları yazar ve sıralama (Flush → fsync → AwaitDurable → Truncate) doğrudur. Boşluk **yalnızca çok süreçli** tazeleme yolundadır; ancak v3.16+ çok süreçlilik kasıtlı olarak desteklenmektedir (`VDbPageStore.pas:1765-1784`, `VDbPageEngine.pas:483-489`).

---

## C-2 — KRİTİK: `.gen` durabil LSN bayat kalır → fsync yapılmadan "durabil" onayı

### Mekanizma
- `.gen` eşlemesinde offset 8 = süreçler arası durabil LSN (`VDbPageStore.pas:1238-1265`). `SetDurableLsn` **monoton**tur: "yalnızca daha büyük değer yazılır" (`1256-1264`) — düşürülemez.
- `AwaitDurable` bu değere güvenip fsync'i **atlar**:
  - `VDbPageEngine.pas:892` `if FDurableLsn >= ALsn then Exit;`
  - `VDbPageEngine.pas:893-899` `shared := FStore.DurableLsn; if shared >= ALsn then ... Exit;`
- Motor açılışta bayat değeri miras alır: `VDbPageEngine.pas:477` `FDurableLsn := FStore.DurableLsn;`
- `.gen`, veritabanı dosyası değiştirilince **silinmez/temizlenmez**:
  - `VDbBackendV3.pas:3884-3886` (SwapDbFile — VACUUM/RESTORE/REKEY ortak yolu): yalnız `.wal` ve `.idx` silinir; `.gen` **kalır**.
  - `VDbPageStore.pas:1837-1857` (OpenEx): mevcut `.gen` ≥ 16 baytsa içindeki değerler **korunur**; `BumpGen` (`1216-1236`) yalnız offset 0'daki sayacı artırır, offset 8'e dokunmaz.

### Senaryo
1. Uzun ömürlü DB: `.gen` durabil LSN = 1.000.000.
2. VACUUM/RESTORE/REKEY → `SwapDbFile` → yeni dosya, LSN uzayı baştan başlar (yeni motor meta LSN'i küçük: `VDbPageStore.pas:1811` `FLSN := 1`).
3. Yeni commit'ler LSN 1, 2, 3… `AwaitDurable(küçük)` → `FDurableLsn (1.000.000) >= ALsn` → **fsync yok**. İstemciye "durabil" döner.
4. Durum, LSN bayat değeri geçene kadar sürer. Aradaki çökmede WAL kayıtları yalnız OS önbelleğindedir → **onaylanmış commit'ler kaybolur**. (Checkpoint'in 8 MB'taki `Truncate` fsync'i (`VDbPageWal.pas:946`) aralığı sınırlar; yine de ~8 MB'lık onaylı-veri penceresi açıktır.)
5. Aynı hata, `.gen`'i kalan bir yolda silinip yeniden yaratılan DB'de de görülür (`OpenEx:1842-1857` bayat dosyayı korur).

### Not
Kod, LSN uzayı kopmasının **diğer** yüzünü (AwaitDurable'ın asla doymaması) biliyor: `VDbBackendV3.pas:3018-3023` ("VACUUM olduysa syncLsn ESKI motora aitti… sonsuz döngü olurdu" → `syncLsn := 0`). Ancak bayat-yüksek durabil LSN'in fsync'i **atlatması** tarafı kapatılmamıştır. `SwapDbFileWith`'e `.gen` sıfırlama (veya DB kimliği/nesil doğrulaması) eklenmelidir.

---

## C-3 — KRİTİK: Temiz kurulum + tahliye + MinLSN atlama → eski sayfa geri gelir

### Mekanizma
1. Başka process'in commit ettiği sayfa, tazelemede **temiz** kurulur: `VDbPageStore.pas:2190-2202` (`Dirty := False`), `3061-3082` (AViewOnly; yalnız `isNew` kirli).
2. Önbellek baskısında temiz kurban **sessizce düşürülür** (yazma yok): `VDbPageStore.pas:2171-2189` — `if FFrames[idx].Dirty then ...spill...`; temizse hiçbir şey.
3. Sayfa tekrar istendiğinde diskten okunur: `VDbPageStore.pas:2218-2219` (`ReadPageAt`) — diskteki sürüm **eski**dir (C-1: yazar checkpoint edene kadar).
4. Sonraki tazelemede aynı WAL kaydı **atlanır**: `VDbPageEngine.pas:447` (`MinLSN = FStore.ViewLsn`) → `VDbPageWal.pas:805-811` (`if lsn <= MinLSN then ... Continue`). Eski imaj kalıcı olur.
5. Okuma yolunda bayatlık denetimi yoktur: `VDbPageStore.pas:2247-2274` (GetPageInternal) yalnız `PageVerify` (yapı+CRC) yapar; `VDbPage.pas:65` "LSN: sayfayı en son değiştiren WAL kaydı" alanı `VDbPage.pas:196`'da 0'a set edilir ve hiçbir yerde okunmaz/karşılaştırılmaz (`grep`: yalnız `VDbCore.pas:5221` — v2 yolu).

### Etki
Süreç B, A'nın onaylı güncellemesini **okuyamaz**; eski değer üzerinden sonraki yazım yaparsa A'nın verisi sessizce ezilir. Crash gerektirmez — çalışma zamanı veri bozulması.

### Doğrulama notu
Senaryo için (a) çok süreçli okuma+yazma, (b) önbellek tahliyesi (havuz doluluğu) gerekir; kilit sıralaması bunu engellemez (okuma paylaşımlı kilitte). "Şüpheli" değil — kod yolu açık; yalnız tetiklenme sıklığı havuz boyutuna bağlıdır.

---

## C-4 — YÜKSEK: FWrittenLsn Refresh/Recover'da eksik → AwaitDurable asılı kalır / fsync fırtınası

### Mekanizma
- `FWrittenLsn`, "WAL'e **fiilen yazılmış** en son LSN" demektir (`VDbPageWal.pas:120-124`).
- `Refresh` onu başlıktan alır: `VDbPageWal.pas:487` `FWrittenLsn := FLSN;` — başlık LSN'i **checkpoint** LSN'idir; gövdede ondan sonraki kayıtlar vardır. Değer kasıtlı olarak düşer.
- `Recover` sonucu son *işlenen* commit LSN'idir: `VDbPageWal.pas:899-901` — MinLSN atlama (`805-811`) sayesinde gövdede bulunan kayıtlar sayılmaz.
- `AwaitDurable` hedefi bu değere sabittir: `VDbPageEngine.pas:905` `target := FWal.WrittenLsn;` sonra `943-944` `if target > FDurableLsn then FDurableLsn := target;` — hedef düşükse FDurableLsn asla bekleyenin LSN'ine ulaşamaz.

### Senaryo (tek process, iki thread — şüpheli derecesinde kolay)
1. T1: `CommitNoSync` → `syncLsn = 106` (`VDbBackendV3.pas:3006`), kilitler bırakılır (`3028-3031`), `AwaitDurable(106)` henüz çağrılmadı.
2. T2 (okuma ya da commit): tazeleme → `FWal.Refresh` (`VDbPageEngine.pas:377`) → `FWrittenLsn := 50` (başlık LSN). Recover MinLSN=ViewLsn=106 ile 106'yı atlar → WrittenLsn 50'de kalır.
3. T1: `AwaitDurable(106)`: `FDurableLsn=50 < 106` → lider → `target := 50` → fsync → `FDurableLsn := 50` → döngü **asla kapanmaz**: her turda fsync ("70.000 fsync/s, ilerleme yok" semptomunun başka bir kopyası), ancak 106'yı geçen yeni bir commit gelirse kurtulur.
4. `Truncate`'ın aynı tehlikeyi bilen yorumu: `VDbPageWal.pas:937-939` — "Sifira cekmek YANLIS olur: … bekleyen AwaitDurable çağrıları eski LSN ile karşılaştırır." Ancak `Refresh` tam olarak bunu yapar.

### Ek etki
`Checkpoint`'in `AwaitDurable(FWal.WrittenLsn)` bariyeri (`VDbPageEngine.pas:1126`) da eksik hedeflenir: gövdedeki 51-106 kayıtları fsync'lenmeden `Truncate` onları silebilir (C-1 ile birleşince veri kaybı).

---

## C-5 — YÜKSEK: Checkpoint/Compact/Restore/Verify, Truncate'ı süreç-kilitsiz çalıştırır

### Mekanizma
- `TVdbPageEngine.Checkpoint` (`VDbPageEngine.pas:1100-1140`) **hiçbir kilit almaz**; Flush→AwaitDurable→Truncate dizisi yalnız sayfa yazımı yan etkisiyle (`WritePageAt → EnsureIoWrite`, `VDbPageStore.pas:2119`, `1091-1109`) tam kilide yükselir — kirli sayfa yoksa o bile olmaz.
- Kilitsiz/eksik kilitli çağrı yerleri:
  - `VDbBackendV3.pas:3598` (Compact/VACUUM), `3547` (Restore): yalnız `FEngCs` (süreç-içi); **süreçler arası** `AcquireDataWrite` yok.
  - `VDbPageEngine.pas:1175-1180` (Verify): hiç kilit yok.
  - (Doğru örnek: `VDbPageEngine.pas:616-618` (Close) ve `VDbBackendV3.pas:2929` (CommitBatch) `AcquireDataWrite` alır → `VDbPageStore.pas:1658-1693` süreçler arası tam kilit + tazeleme.)
- `Truncate` LSN'e bakmaksızın tüm gövdeyi siler: `VDbPageWal.pas:943`.

### Senaryo (şüpheli — çok süreçli)
B eşzamanlı olarak commit eder (kayıtlar WAL'e yazıldı, fsync'li; sayfalar B önbelleğinde/kirli). A (Verify/VACUUM/kapanış) kilitsiz `Checkpoint(True)` çalıştırır: Flush B'nin sayfalarını yazmaz, `Truncate` B'nin WAL kayıtlarını siler. B çökerse commit kaybolur; `AwaitDurable(FWal.WrittenLsn)` (`1126`) yalnız kayıtların fsync'ini garantiler, **veri dosyasına inişini değil**.

### Not
Süreç-içi `FEngCs` çoğu yarışı kapatır; bulgu süreçler arası senaryoyla sınırlıdır. Yine de `Checkpoint`'in "Flush'tan önce tüm WAL içeriği veri dosyasında olmalı" varsayımı (C-1) ve kilit boşluğu birleşince risk katlanır.

---

## C-6 — YÜKSEK: CommitNoSync → AwaitDurable arası istisnada yanlış durum raporlama

### Mekanizma
`VDbBackendV3.pas:2982-3037` (CommitBatch):
1. `3006` `FEng.CommitNoSync(syncLsn)` — WAL'e yazıldı (fsync yok); yazma kümesi bırakıldı (`2984-2995`), `FDirty := False` (`3010`).
2. `3011` `LogFinish`, `3017` `MaybeCheckpoint` — **istisna fırlatabilir** (ör. `Checkpoint(True)` içinde fsync/yazma hatası: `VDbPageEngine.pas:1119-1127`; `VDbSync.pas:182-196` fsync hatasında raise eder).
3. İstisna, `finally` bloklarını (`3028-3031`, `3041-3043`) çalıştırıp `3037` `AwaitDurable(syncLsn)`'yi **atlar**.
4. Sonuç: transaction **uygulanmış ve WAL'dedir** (kurtarılabilir) ama istemci HATA alır. İstemci "hata = uygulanmadı" varsayımıyla yeniden denerse **çift uygulama**; telafi işlemi yaparsa tutarsızlık.
5. `DoCommit` ayrıca fsync'den **önce** `FStore.EndTxn; FInTxn := False` yapar (`VDbPageEngine.pas:1069-1070`) — dayanıklılık beklenmeden işlem kapanır (grup commit sözleşmesi gereği; ancak yukarıdaki hata yollarında bu, "başarıyla kapandı" izlenimini güçlendirir).

### Ek
`VDbBackendV3.pas:975-981` (LogFinish): "VERI kaybi YOK (commit zaten durabil)" yorumu yanlıştır — o noktada fsync henüz yapılmamıştır (`AwaitDurable` sonda). Ayrıca `FDurableChangeLog=True` ise (`VDbChangeLog.pas:941-942` fsync) günlük kaydı WAL fsync'inden **önce** kalıcı olur → CDC/PITR, gerçekleşmemiş bir commit'i görebilir (bkz. C-12).

---

## C-7 — YÜKSEK: StoreRefreshed korumaları geç çalışır; FPendingCount kontrolü etkisiz

### Mekanizma
`VDbPageEngine.pas:343-467` (StoreRefreshed):
- Tam yol: `396` `FStore.DropCache` — **açık işlemin kirli sayfalarını yok eder**; `408` `InstallPending(True)` — açık işlemin tahliye edilmiş (pending) imajlarını kurar ve `ClearPending` ile listeyi **boşaltır** (`VDbPageEngine.pas:1097`).
- Koruma **bundan sonra** gelir: `421-424` / `460-463` `if FInTxn or (FPendingCount > 0) then raise ...` — `FPendingCount` artık 0'dır (dead-code); `FInTxn` ihlali ise çok geç: DropCache kirli sayfaları silmiş, pending imajlar temiz (view) kurulmuştur (`InstallPage(..., True)` → `Dirty=False`, `TxnMark=0`).
- Sonuç: açık işlem kurtarılamaz durumdadır ve hata fırlatılsa bile:
  - pending'e düşmüş sayfa imajları commit'te **atlanır** (DoCommit adım 2 yalnız `Mark = FStore.TxnId` olanları yazar, `VDbPageEngine.pas:1015-1017`; view kurulumda `TxnMark := 0` olmuştur, `VDbPageStore.pas:3013`) → **kısmi/kaybolan commit**.
  - DropCache ile silinen kirli sayfalar (yazılmamış işlemler) geri gelmez.

### Not
"Şüpheli": backend yolu `FEngCs + AcquireDataWrite` içinde tazeleme yaptığı için (`VDbBackendV3.pas:2929`) asıl risk **motor API'sini doğrudan** kullanan oturumlarda (`VDbPageEngine.pas:1071-1074` yorumu bu kullanımı resmen tanır) ve süreçler arası commit anındadır. Yine de koruma kodunun sırası hatalıdır.

---

## C-8 — YÜKSEK (şüpheli, dar pencere): Artımsal tarama koruması dosya başlığını doğrulamaz

### Mekanizma
`VDbPageWal.pas:759-766` (Recover):
```
hdrLsn := FLSN;
... if AIncremental and (FScanPos >= VDB_PAGE_SIZE) and
      (FScanHdrLsn = hdrLsn) and (FScanPos <= FStream.Size) then startPos := FScanPos;
```
- `hdrLsn := FLSN` **bellekteki** değerdir; diskteki WAL başlığı okunmaz. `FLSN` ayrıca `Commit`'te de güncellenir (`VDbPageWal.pas:652`). Korumanın iddia ettiği "başlık LSN'i değiştiyse dosya kesilmiştir" (`125-134` yorumu) yalnızca bu nesnenin **kendi** Truncate'ını yakalar.
- `Refresh` (`473-492`) FScanPos'u sıfırlamaz; başlık LSN'ini diske göre tazeler ama eşit kalabilir (aynı CheckpointLSN ile yeniden truncate).
- `FScanPos <= FStream.Size` yalnızca **küçülmeyi** yakalar; truncate sonrası dosya yeni kayıtlarla FScanPos'un ötesine **yeniden büyüyünce** koruma bayılır.

### Sonuç
Bellek-içi tutarlılık sağlanmış olsa da (`131-134`: "bu alanlara yalnız kilit altında erişilir"), kilit yalnız tarama anını korur; taramalar **arasında** başka process dosyayı truncate+yeniden yazabilir. Yanlış konumdan devam eden tarama:
- Çoğu durumda `TornTail`'e düşer → o tarama hiçbir şey uygulamaz ve kayıtlar **sessizce** uygulanmamış kalır (C-10 ile birleşince sessiz bayatlık).
- Şans eseri sihirli sayı eşleşirse kayıtlar atlanabilir/yanlış yorumlanabilir.

### Not
"Şüpheli": gerçekleşme için (a) süreçler arası truncate, (b) aynı başlık LSN'i, (c) dosyanın FScanPos'u aşacak kadar yeniden büyümesi, (d) bizim process'in arada commit etmemesi gerekir. Dar ama gerçek. Sağlam koruma: `FScanPos`'ta disk başlığını/kayıt sınırını yeniden doğrulamak ya da (FileSize, başlık LSN, kayıt sayacı) üçlüsünü saklamak.

---

## C-9 — ORTA: WAL başlığı yarım yazılınca veritabanı hiç açılamaz

### Mekanizma
- `Truncate`: `FStream.Size := VDB_PAGE_SIZE` → `WriteHeader` → `VDbFlushStream` (`VDbPageWal.pas:943-946`). `WriteHeader` (`274-309`) 4096 baytı tek `WriteBuffer` ile yazar; çökme yazımın ortasında olursa başlık CRC'si bozulur.
- `ReadHeader` (`337-340`): `raise EVdbWal.Create('WAL basligi bozuk (CRC tutmadi)')`; `Open` (`431-438`) istisnayı yeniden fırlatır; `TVdbPageEngine.Open` (`VDbPageEngine.pas:480`) yakalamaz → **açılış tamamen başarısız**.
- Oysa bu noktada WAL **atılabilir** durumdadır: checkpoint `FStore.Flush(True)` ile veri dosyasını çoktan fsync etmiştir (`VDbPageEngine.pas:1119`); başlık bozukluğu = boş WAL demektir. Sağlam tasarım bozuk/uzlaşmaz WAL başlığını "içerik yok" sayıp yeni başlık yazar (şifre/tuz doğrulaması korunarak).
- İlgili pencere: `Open`'daki ilk `WriteHeader` (`VDbPageWal.pas:451-454`) — dosya < 4096 ise `Open` yeni dosya yaratıp üzerine yazar (`420-424`, `451`), bu dal güvenli.

### Etki
Erişilebilirlik: veri dosyası eksiksiz ve güncel olduğu halde DB açılamaz; operatör müdahalesi gerekir (yanlış müdahale — örn. `.wal` yerine `.odb` silme — veri kaybına dönüşebilir).

---

## C-10 — ORTA: TornTail sessizce yutulur; orta-şerit bozulmada sonraki tüm commit'ler kaybolur

### Mekanizma
- `Recover` bozuk/kesik kayıtta `Stats.TornTail := True` yapıp **durur** (`VDbPageWal.pas:773-837`); kuyruktan sonrası hiçbir zaman uygulanmaz. Yorum "yalnızca bir commit kaydıyla kapanmış çerçeveler uygulanır" (`22-24`) kuyruk için doğrudur; ancak bozulma **dosya ortasında** ise (bit çürümesi, yarım yazım) sonraki **tüm onaylı commit'ler** sessizce atlanır.
- Motor bunu yalnız `FWalStats`'a yazar (`VDbPageEngine.pas:508`, `405`, `448`); `RecoveryStats` özelliği (`197`) dışa açıktır ama açılış/tazeleme yolunda hiçbir uyarı/istisna üretmez, kullanıcıya raporlanmaz.
- `FScanPos := goodPos` (`VDbPageWal.pas:900`) bozukluk noktasında durur; sonraki artımsal tarama aynı noktada tekrar takılır — kalıcı sessiz kayıp.
- `CommitCount` (`905-924`) aynı taramayı `Apply=nil` ile yapar; `TornTail` durumunda eksik sayar → AS OF üst sınırı (`VDbBackendV3.pas:2432-2441`) yanlış olabilir.

### Öneri
TornTail'i açılışta açık bir uyarı/istatistik olarak yüzeye çıkarmak; orta-şerit bozulmada (kuyruk değilse) hatayı yükseltmek.

---

## C-11 — ORTA (şüpheli): AS OF — taban+WAL kopyası atomik değil

### Mekanizma
`VDbBackendV3.pas:2415-2473` (ScanAllAt):
- `2432` `total := FEng.Wal.CommitCount` (WAL'i kilitlenmeden tarar), `2454` `CopyBaseImageTo(tmp)`, `2456` `AsOfCopyFile(FPath + '.wal', tmpWal)`. Bu kopyalar `FEngCs` **dışında** ve süreçler arası yazma kilidi alınmadan yapılır.
- Eşzamanlı bir checkpoint WAL'i tam bu anda truncate ederse: taban kopyası **yeni**, WAL kopyası boş/kesik olabilir. Geçici motor `eng.RecoverLimit := n` ile açılır (`2461`) ve kurtarma eksik commit uygular → `ActualSequence = n` raporlanır ama görüntü tabanın yeni durumudur → **zaman noktası tutarsız** (AS OF, n. anı değil).
- Geçici motorun `Open`'ı WAL'i budar (`VDbPageEngine.pas:549-553`) — bu kopya olduğu için zararsız; gerçek `.wal` korunur. (Doğru tasarım.)

---

## C-12 — ORTA: Değişim günlüğü / WAL fsync sıralaması ve yanlış "durabil" yorumu

- `CommitBatch`: `3006 CommitNoSync` (WAL yazımı, fsync yok) → `3011 LogFinish` (`VDbChangeLog.pas:894-969`; `FSyncGroups=True` ise `941-942` fsync) → `3037 AwaitDurable` (WAL fsync). Yani `FDurableChangeLog=True` iken **günlük, WAL'den önce** kalıcı olur; çökmede CDC/PITR, motor tarafında hiç gerçekleşmemiş bir değişikliği "gerçekleşmiş" olarak yayınlayabilir (replikasyon hayalet verisi).
- `VDbBackendV3.pas:977-978`: "commit zaten durabil" yorumu CommitNoSync sonrası **yanlıştır** (fsync sonda). Yorum değil davranış hatası değil; ancak LogFinish hatasının sigortasızlık derecesini yanlış anlamaya yol açar.
- `EndGroup` hata yolunda yarım grubu geri alır (`VDbChangeLog.pas:945-960`) — iyi; `AbortGroup` ile kuyruk bozulmaz.

---

## C-13 — DÜŞÜK: WAL.Bytes() şifreli modda çerçeveyi yanlış boyutlar

- `VDbPageWal.pas:950-956`: `FWrittenBytes + FBufferCount * (VDB_PAGE_SIZE + VDB_WAL_REC_HDR)`. Oysa şifreli modda gerçek çerçeve boyu `VDB_ENC_ENVELOPE + VDB_WAL_REC_HDR` (`653-656`, `557-608`).
- Etki: `MaybeCheckpoint` eşiği (`VDbBackendV3.pas:1613-1623`, 8 MB) şifreli DB'de geç ölçülür → WAL daha büyük büyür; kurtarma süresi artar. Kayıp yok.

## C-14 — DÜŞÜK: WAL.Commit fsync hatasında tampon temizlenmez

- `VDbPageWal.pas:692-705`: `WriteBuffer` sonrası `if DoSync then VDbFlushStream` — fsync istisnasında `FBufferCount` temizlenmez ve `FWrittenBytes` artmış, kayıtlar dosyaya yazılmıştır. Yeniden commit çerçeveleri **yeniden** yazar (yinelenen kayıt; kurtarmada son-imaj-kazanır olduğundan çoğunlukla zararsız). 4 MB üstü tampon `697-698`'de sıfırlanırsa ikinci denemede yük alanı **sıfır dolu** yazılır (PageSeal CRC'si tutmadığı için kurtarma TornTail'de durur — sessiz kırpılma).
- Not: mevcut çağrı grafiğinde `DoCommit` her zaman `DoSync=False` geçer (`VDbPageEngine.pas:855`, `863`, `1057`); yol pratikte ölü — yine de API sözleşmesi olarak riskli.

## C-15 — DÜŞÜK: Recover'da MaxCommits kesilmesinde goodPos güncellenmiyor

- `VDbPageWal.pas:865-878`: commit işlenip `if (MaxCommits > 0) and (Stats.Commits >= MaxCommits) then Break` — `goodPos := FStream.Position` (878) bu kırılmada çalışmaz; `FScanPos` bir önceki kaydın sonunda kalır (`900`). Sonraki artımsal tarama aynı commit kaydını yeniden okur (çerçeveler atlandığından zararsız; `Stats.Commits` çift sayılabilir). Yalnız AS OF + artımsal tazeleme birleşiminde görünür.

## C-16 — BİLGİ: Sayfa LSN damgası kullanılmıyor

- `VDbPage.pas:65` sayfa başlığında "sayfayı en son değiştiren WAL kaydı" alanı var; `VDbPage.pas:196` (PageInit) 0 yazar, v3 motoru hiç güncellemez/doğrulamaz (yalnız `VDbCore.pas:5221` — v2). C-3'teki "bayat sayfa diskten geri geldi" senaryosu, okuma yolunda LSN damgası karşılaştırmasıyla (sayfa LSN'i > depo ViewLsn ise reddet/WAL'e bak) önlenebilirdi.

---

## Olumlu bulgular (denge için)

1. **Tek süreçli checkpoint sıralaması doğru:** `Flush(DoSync)` → `AwaitDurable(WrittenLsn)` → `Truncate` → `.gen` publish (`VDbPageEngine.pas:1119-1135`); budama öncesi grup-commit bariyeri bilinçli (`1122-1125`).
2. **Kurtarma sıralaması doğru:** meta sayfa (0) en son uygulanır (`VDbPageWal.pas:881-889`); commit'siz kuyruk atılır.
3. **Butünlük katmanları sağlam:** kayıt CRC (başlık; v2'de sayfa seal CRC — `VDbPageWal.pas:827-860`), sayfa CRC (`VDbPage.pas:289-293`), meta başlık CRC (`VDbPageStore.pas:820-823`), şifreli WAL'de tuz/anahtar doğrulaması (`VDbPageWal.pas:345-369`).
4. **Açılış doğrulaması iyi:** meta sihirli sayfa/sürüm/sayfa boyu/CRC/dosya boyu vs. sayfa sayısı (`VDbPageStore.pas:801-836`); `.idx` bayatlık denetimi LSN+sayfa sayısı+boyut (`VDbPageHeap.pas:1236-1260`).
5. **fsync hataları yutulmaz:** `VDbSync.pas:182-196` raise eder; `AwaitDurable` hatayı bekleyenlere de yayar (`VDbPageEngine.pas:900-901`, `948-959`).
6. **`.gen` durabil LSN yalnızca başarılı fsync sonrası ve monoton yayınlanır** (`VDbPageEngine.pas:945-946`, `VDbPageStore.pas:1256-1264`) — yayın yönü güvenli; sorun (C-2) bayat değerin düşürülememesinde.

---

## Öncelikli düzeltme önerileri

1. **C-1/C-3 (kök neden aynı):** Tazelemede kurulan (view) imajları **kirli** işaretlemek ya da Checkpoint'te "ViewLsn'den eski ama dosyaya yazılmamış" sayfaları da Flush'a dahil etmek. Truncate yalnızca `Flush`'ın gerçekten yazdığı LSN'e kadar budanabilmeli (sayfa-başı kirli izi veya WAL-imaj-temizlik izi gerekir).
2. **C-2:** `SwapDbFile`/`SwapDbFileWith` içinde `.gen`'i silmek veya durbil LSN alanını sıfırlamak (DB nesil kimliği ile birlikte).
3. **C-4:** `FWrittenLsn`'i "dosyadaki son kaydın LSN'i" olarak tutmak (Refresh'te başlıktan değil; Recover'da atlanan kayıtları da sayarak ya da dosya sonundan okuyarak).
4. **C-5/C-6:** `Checkpoint`'e `AcquireDataWrite` zorunluluğu; `CommitBatch`'te `CommitNoSync` sonrası `AwaitDurable`'ı try/finally içinde garantiye almak ve "sonucu belirsiz" ayrı hata tipi vermek.
5. **C-8:** `FScanPos`'ta kayıt sınırını disk başlığı + kayıt sihirli sayısından yeniden doğrulamak.


---

# EK-D — Islevsel Dogruluk Hatalari ve Sinir Durumlari

# Kod İnceleme Raporu — Eksen D: İşlevsel Doğruluk Hataları ve Sınır Durumları

- **Dal / commit:** `v3` @ `8b98b01` (P-97)
- **Odak:** VDbTable.pas (Insert yolları, ApplyIdentity, VDbApplyGenerated, EncodeRowInto, IdxAddRow, batch/non-batch), VDbExecutor.pas, VDbSql.pas, VDbParser.pas, VDbAst.pas
- **Mod:** Salt okunur. Hiçbir dosya değiştirilmedi, derleme/çalıştırma yapılmadı.
- **Not:** Satır numaraları yukarıdaki commit'in güncel hâlidir. Görev notlarındaki numaralar (örn. `:9639`, `:9756`) ~800 satırlık büyüme nedeniyle kaymış; güncel karşılıkları aşağıda verilmiştir.

---

## 1. Bilinen açık konu (P-67) — TEŞHİS DÜZELTMESİ + GERÇEK VECTÖR

Görev notu diyor ki: *"FBatchHasIdentity/FBatchHasGenerated dolduruluyor ama HİÇ OKUNMUYOR; tamamlanması gereken yer `:9756-9760`'taki koşulsuz ApplyIdentity/VDbApplyGenerated çağrıları."*

**Bu teşhis güncel koda uymuyor.** P-67 **tamamlanmış** görünüyor:

- Bayrak bildirimi: `VDbTable.pas:387-388` (`FBatchHasIdentity`, `FBatchHasGenerated`)
- Bayrak okuma + koşullu çağrı (GÜNCEL): `VDbTable.pas:10593-10597`
  ```pascal
  if FBatchHasIdentity then
    ApplyIdentity(tp^, vals);          // 10593-10594
  if FBatchHasGenerated then
    VDbApplyGenerated(tp^, vals);      // 10596-10597
  ```
  Bu çağrılar **koşullu** (bayrak okunuyor), `:9756-9760` iddia edildiği gibi **koşulsuz değil**. Dolayısıyla "hiç okunmuyor" ifadesi geçersiz.
- Bayrak atama noktaları: `10464-10470` (Path 1), `10501-10507` (Path 3 / batch kurulumu), `10519-10525` (Path 4).
- Karşılaştırma: `InsertReturning` (`VDbTable.pas:11875-11876`) ve `UpsertRowReturning` bayrakları **kullanmaz**, her seferinde taze `GetTable` + koşulsuz `ApplyIdentity/VDbApplyGenerated` çağırır → bu yollar güvenli ama yavaş. P-67 optimizasyonu yalnızca ana `Insert` yolunda.

### 1a. GERÇEK ve ERİŞİLEBİLİR hata: DDL-inside-batch sonrası bayat bayrak/şema önbelleği — **[KRİTİK]**

P-67 bayrakları artık okunuyor, **ancak** bayraklar ile `FBatchTableDef` önbelleği **yalnızca tablo ADI** üzerinden geçerli kılınıyor ve yalnızca batch yaşam döngüsünde sıfırlanıyor. Bir transaction içinde DDL + DML karıştırıldığında bayat kalır.

**Kanıt zinciri:**

1. **Bayraklar ne zaman hesaplanır:** Yalnızca (a) tablo adı değiştiğinde (`10459` `if FPrefixCacheName <> tp^.Name`, `10514` aynı) ya da (b) batch tablo önbelleği kurulurken (`10501-10507`). `Path 2` (batch cache) bayrakları **yeniden hesaplamaz** (`10474-10478`).
2. **Önbellek ne zaman sıfırlanır:** Yalnızca `ResetBatchTableCache` (`6421-6436`) — o da yalnızca `BeginBatch` (`6445`), `CommitBatch` (`6452`), `AbortBatch` (`6472`, `6495`), `ReloadSchema` (`6415`), `RollbackToSavepoint` (`6373`) ve constructor (`5211`). **ALTER/CREATE/DROP/RewriteTable/MarkSchema çağırmaz.**
3. **DDL batch içinde izinli:** `MarkSchema` (`6038-6046`): `if FKvB.InBatch then FSchemaDirty := True` — yani DDL açık transaction içinde çalışabilir. `ExecAlterTable` (`VDbExecutor.pas:19015-19046`) `FT.Alter*` çağrısını kendi transaction sarmalı olmadan yapar; SQL `BEGIN` → `FT.BeginBatch` (`19059`).
4. **ALTER kendi başına sıfırlamaz:** `AlterAddColumn` (`8948-9048`) `ownDdl := not FKvB.InBatch` (`9037`); zaten batch içindeyse `BeginBatch/CommitBatch` **çağırmaz** (`9038-9043`) → `ResetBatchTableCache` tetiklenmez.

**Erişilebilir tetik dizisi (tek iş parçacığında):**
```sql
BEGIN;
INSERT INTO A(a) VALUES(1);                 -- Path 3: A'nın şeması + bayraklar önbelleğe alınır
ALTER TABLE A ADD COLUMN g INT GENERATED ALWAYS AS (a*2) STORED;  -- ownDdl=False → önbellek SIFIRLANMAZ
INSERT INTO A(a) VALUES(2);                 -- Path 2: BAYAT FBatchTableDef + BAYAT FBatchHasGenerated=False
COMMIT;
```
- 2. `INSERT`, `FBatchTableDef.Name = 'A'` olduğu için `Path 2`'yi seçer (`10474`), taze `GetTable` çağırmaz.
- `FBatchHasGenerated` hâlâ `False` → `VDbApplyGenerated` **atlanır** → `g` kolonu hesaplanmaz.
- Satır, ALTER öncesi kolon sayısıyla kodlanır. `DecodeRow` satır başlığındaki `H.ColCount` ile kendi kendini tanımlar (`4285`) ve sınırları kontrol eder (`4267-4299`) → OOB bozulma olmaz, **ama** satır yeni şemadan daha az kolonla döner; `SELECT *` hizasız/eksik kolon üretir = **yanlış sorgu sonucu**.
- 2. `INSERT` yeni kolonu `ColNames` içinde belirtirse, `FindCol` bayat tanımda bulamaz → sahte `kolon yok: g` ya da sessiz kayıp.

**Etki:** Yanlış sorgu sonucu / eksik-kayık kolon. Görevin şiddet tanımına göre **KRİTİK** ("yanlış sorgu sonucu"). Tek ön koşul: bir transaction içinde hedef tabloda önce INSERT, sonra ALTER, sonra tekrar INSERT.

**Kapsam notu (daraltma):** Non-batch `Path 1/4` bu bayatlıktan **etkilenmez** — tek başına çalışan DDL kendi batch'ini açar/kapatır (`ownDdl=True`) ve `ResetBatchTableCache` çağırır, `FPrefixCacheName` sıfırlanır. Bug yalnızca **batch yolu (Path 2)** ile sınırlıdır.

### 1b. Görevin literal "non-batch B araya girme" senaryosu — **erişilemez (teşhis hatalı), eşzamanlılık varyantı ŞÜPHELİ**

Görev iddiası: *"batch tablo A'dayken araya non-batch Insert tablo B girerse bayraklar B için hesaplanır, A'nın batch dalı yeniden hesaplamaz."*

Kodda **doğrulandı ki bu, normal transaction akışında tetiklenemez:**
- Non-batch `INSERT`, `inBatch := FKvB.InBatch` (`10451`) = `False` gerektirir.
- `FBatchTableCached := True` yalnızca batch içinde (`10494`) ve tüm batch sınırlarında sıfırlanır (`6445/6452/6472`).
- Dolayısıyla önbellek canlıyken (`FBatchTableCached=True`) non-batch `INSERT` çalışamaz; ikisi çelişkir. `BEGIN/COMMIT` her zaman `ResetBatchTableCache` çağırır.
- Eşzamanlılık: `RequireSoleTxn` (`6048-6059`) DDL/savepoint için `FKvB.SoleWriter` şartı koşar; `VDbTable.pas:349` "Yalnız ANA thread erişir", `:1065` F-41 oturum thread-yerel. Yazmalar tek ana thread'de seri göründüğünden iki oturumun bayrakları yarıştırması **düşük olasılıklı**. Bu eşzamanlılık tetiği **ŞÜPHELİ** (tam oturum/kilit modeli doğrulanmadı).

**Sonuç:** Literal senaryo yanlış teşhis; aynı bayat-bayrak **sonucunu** üreten gerçek ve erişilebilir vektör **1a'daki DDL-inside-batch** yoludur.

---

## 2. Bulgular (şiddete göre)

### [YÜKSEK] SUM/AVG toplu-biriktirici Double hassasiyet kaybı (>2^53 Int64)
- `VDbSql.pas:2308` — `fv, sum: Double;`
- `VDbSql.pas:2356-2357` — `if VDbParseInt(frows[s][A], iv) then sum := sum + iv` (Int64 → Double biriktirici)
- `VDbSql.pas:2367` — `if intOnly then Exit(IntToStr(Trunc(sum)))`
- `VDbSql.pas:2371-2372` — `Round(sum) mod cnt` / `Round(sum) div cnt`
- **Neden yanlış:** `Double` yalnızca 2^53'e kadar tam sayıları birebir temsil eder. Büyük `BIGINT` sütunlarında (ID, tutar, sayaç) `SUM`/`AVG` sessizce yanlış sonuç üretir. `Trunc`/`Round` `Int64` döndürür; `|sum| > High(Int64)` olduğunda taşar.
- **Kanıtlı tutarsızlık:** Kod tabanı bunu zaten bir hata sayıyor — `VDbIdxCmp` yorumu `VDbTable.pas:1980-1986`: *"Double 2^53'ten büyük tam sayıları temsil edemediği için büyük id'ler yanlış sıralanırdı"* (INTEGER artık `Int64`). Aynı hata `AggOf` SUM/AVG'de **yeniden üretiliyor**.
- **Erişilebilirlik:** `AggOf` GROUP BY çıktı satırlarını üretir (`VDbSql.pas:2504`, `2528`). `SELECT SUM(bigint_col) ... GROUP BY ...` yanlış sonuç verir.

### [YÜKSEK] Pencere/toplu fonksiyon SUM/AVG da Double + hepsi-float ayrıştırma
- `VDbExecutor.pas:8211` — `sum: Double;`
- `VDbExecutor.pas:8430-8432` — `if VDbParseFloat(v, fv) then sum := sum + fv` (integer değerler de float ayrıştırılır)
- `VDbExecutor.pas:8439`, `8442` — `VDbFloatToStr(sum)`, `sum / navg`
- **Neden yanlış:** `AggOf` ile aynı Double taşma/hassasiyet kaybı; ayrıca integer `SUM` float biçiminde döner (`AggOf` ise `intOnly`'de `IntToStr`). İki SUM yolu tip/biçim olarak tutarsız. (AVG `navg=0` koruması doğru: `8442`.)

### [ORTA] `try FT.AbortBatch; except end;` — geri alma hatası yutuluyor
- `VDbExecutor.pas:17104` — `try FT.AbortBatch; except end;`
- **Neden yanlış:** Hata sarmalı sırasında en-iyi-çaba geri alma. Orijinal korunur (iyi), ama `AbortBatch` kendisi hata verirse yarım geri alma **sessizce** geçer; sonraki COMMIT/ROLLBACK bayat sema yedeğiyle çalışabilir. İncelenen benzersiz sarmal-`except` bu; boş bırakma türü tek örneği.
- **Not:** Kasıtlı bir desen olabilir; yine de günlüklenebilir/raporlanabilir olmalı.

### [DÜŞÜK] AutoInc / MaxPkInt `+1` taşması (yalnızca teorik sınır)
- `VDbTable.pas:6143` (`iv := AutoIncOf(T) + 1`), `6147` (`MaxPkInt(T) + 1`), `10607`, `10619-10621`
- **Neden yanlış:** `AutoIncOf`/`MaxPkInt` `Int64`; `High(Int64)` değerinde `+1` `Low(Int64)`'a sarar → sentetik/oto PK negatif olur, çarpışma. ~9.2e18 satır gerektirdiğinden pratikte imkânsız; kayda değer ama düşük.

### [DÜŞÜK] `VDbNormValue` tarih/saat normalizasyonunda locale-fallback
- `VDbTable.pas:1947-1963` — `TryStrToDate(v,d,fs)` başarısızsa `TryStrToDate(v,d)` (varsayılan/locale ayarları)
- **Neden yanlış:** Açık `yyyy-mm-dd` ayrıştırması başarısız olup locale yorumu başarılıysa, belirsiz girdi (örn. `03/04/2024`) sessizce farklı yorumlanabilir (gg/aa vs aa/gg). `VCT_TIME` `hh:nn:ss`'e normalize edilirken saniye-altı atılır (`1957`). Sonuç üretir ama yorum tutarsız olabilir.
- **Not:** Ayrıştırma başarısızlığında hata fırlatır (yutma yok); yalnızca fallback yorum riski.

### [BİLGİ] Tip çıkarsama yolunda exception yutma (zararsız)
- `VDbExecutor.pas:3047-3051` — `try Td := FT.GetTable(Sel.FromTable); except Exit; end;`
- En-iyi-çaba tip çıkarsama; tablo yoksa sessizce çıkıp varsayılana düşer. Yanlış sonuç üretmez; yalnızca bilgi.

### [BİLGİ] `VDbIdxCmp` NULL sıralaması PostgreSQL'den farklı (kasıtlı olabilir)
- `VDbTable.pas:1989` — *"NULL (boş string) her zaman en başta."* PostgreSQL ASC'te `NULLS LAST` varsayılanıdır. Tasarım tercihi olabilir; ORDER BY NULL konumu beklentisiyle çelişir. Bağımsız kanıtlanabilir yanlışlık yok.

---

## 3. Doğrulanan — sağlam bulunan noktalar (kapsam kanıtı)

- **Dizi sınırları / High(vals):** `ApplyIdentity` (`6127` `if i > High(Vals) then Continue`), `VDbApplyGenerated` (`2582`, `2587` `i < Length(Vals)`), `VDbIdxJoin` (`2617`, `2631` `Cols[i] < Length(Vals)`) sınırları kontrol ediyor. `Insert` `Length(ColNames) <> Length(StrVals)` eşitliğini zorlar (`10534-10536`) — sessiz eksik/fazla değer yutulmaz.
- **COUNT semantiği:** `COUNT(*)` = `Length(Members)` (`2317-2318`); `COUNT(col)` yalnız NULL-olmayan sayar (`2319-2322`) — SQL'e uygun. `MIN/MAX` NULL atlar (`2330`, `2343`).
- **Boş grup / sıfıra bölme:** `AggOf` `cnt = 0` → `Exit('')` (`2364`); pencere AVG `navg > 0` korumalı (`8442`).
- **Satır kod/çözme sınırı:** `DecodeRow` başlık + kolon sınırlarını kontrol eder (`4267`, `4268`, `4275`, `4290`, `4292`, `4299`); `H.ColCount` ile kendi kendini tanımlar (`4285`). `EncodeRowInto` `Grow` kapasite büyütür (`3771-3781`), `PutLenCode` NULL=0 (`3806-3810`).
- **UNIQUE + NULL:** `IdxAddRow` boş (NULL) anahtarı UNIQUE haritasına yazmaz (`7887` `if (key <> '')`), partial indeks predicate + expression indeks ele alınmış (`7861`, `7864`). Bağımsız hata yok.
- **IDENTITY güncelleme koruması:** `VDbCheckIdentityUnchanged` (`2592-2604`) UPDATE'te identity değişimini reddeder.
- **AutoInc dayanıklılığı:** `AutoIncPersistOf` (`6154-6169`) kayıt alanı + sözlük + batch önbellekten `max` alır; `P-64` bayat sayaç yazımını önler.
- **InsertReturning / UpsertRowReturning:** bayrak önbelleğini kullanmaz, her defasında taze `GetTable` + koşulsuz `ApplyIdentity/VDbApplyGenerated` (`11875-11876`) → P-67 bayatlığından etkilenmez.

---

## 4. Şüpheli / doğrulanamayan

- **[ŞÜPHELİ] Eşzamanlı oturumların ortak `FBatch*` önbelleğini yarıştırması (1b):** `FBatchTableDef`, `FPrefixCacheName`, `FBatchHas*`, `FBatchVals` örnek (instance) alanları; iki oturum tek `TVTableDb` üzerinde seri olmayan yazarsa literal "non-batch B araya girme" bayatlığı oluşur. Ancak "yalnız ana thread" (349) + thread-yerel oturum (1065) seri yazmaya işaret ediyor; tam kilit modeli doğrulanmadı. Doğrulanmış bir tetik yok.
- **JOIN / ORDER BY / LIMIT uç durumları:** Yoğun `VDbExecutor.pas` içinde tek tek doğrulanmadı (kapsam/ağırlık gereği). `VDbIdxCmp` düzeltmesi INTEGER sıralamasını doğru; JOIN eşleşme ve LIMIT/OFFSET uçları (LIMIT 0, OFFSET > satır) ayrıca ele alınmalı. Kapsam dışı kalan bu alanlar için ek inceleme önerilir.

---

## 5. Öneriler (öncelik sırasıyla)

1. **P-67 / DDL-inside-batch (KRİTİK):** `ResetBatchTableCache`'i (veya yalnız `FBatchTableDef` + `FBatchHas*` + `FBatchColMapValid` geçersiz kılmasını) her `FTables.AddOrSetValue` / `RewriteTable` / şema değişikliğinde çağır. En dar düzeltme: `AlterAddColumn/DropColumn/RenameColumn/AlterColumnType/CreateTable/DropTable` gövdesine `ResetBatchTableCache` ekle (batch içinde olsa bile). Böylece `Path 2` bayat önbellekle çalışmaz.
2. **SUM/AVG (YÜKSEK):** Integer biriktirmeyi `Int64`/`Extended`'a al ya da `sum: Double`'ı yalnız float girişte kullan; integer toplamı `Int64` biriktirici + taşma kontrolü ile yap (bkz. `VDbIdxCmp`'deki 2^53 kararıyla tutarlılık). `AggOf` ve pencere yolu (`8211`) ikisi de düzeltilmeli.
3. **`try FT.AbortBatch; except end;` (ORTA):** En azından `except` içine iz günlüğü/uyarı ekle; tam geri alınamama sessiz kalmasın.
4. **`VDbNormValue` tarih fallback (DÜŞÜK):** Locale fallback'i kaldır veya yalnızca `yyyy-mm-dd` kabul et; `TIME` için saniye-altı politikasını netleştir.


---

# EK-E — Performans Firsatlari (INSERT Yolu)

# VDb v3 — Performans Denetimi Raporu (INSERT Yolu)

- **Kapsam:** Yalnızca "performans iyileştirme fırsatları" ekseni. Salt okunur inceleme; hiçbir dosya değiştirilmedi, derleme/ölçüm yapılmadı.
- **Ağırlıklı dosyalar:** VDbTable.pas, VDbExecutor.pas, VDbSql.pas, VDbParser.pas, VDbPageHeap.pas, VDbPageEngine.pas, VDbBackendV3.pas
- **Ölçüm tabanı (hedefler):** tb.Insert 6,39 µs/satır (SQLite 3,12); SQL text batch 12,22 µs/satır; multi-row VALUES 7,62 µs/satır; tek satır autocommit 0,38 ms/commit; bulk 1000 satır 1,916 ms/işlem. Isınmış bileşenler: EncodeRow + IdxAddRow + Put.
- **Bulgular "tahmin" etiketlidir**; hiçbir değeri bu incelemede ölçmedim. Bazı maliyetler kod içi yorumlardaki kendi ölçümlerine dayanır (kaynak gösterilir).

---

## Yönetici özeti

Motorun depo katmanı (VDbPageHeap/VDbPageEngine/VDbBackendV3 ApplyBatch) ve satır kodlama (EncodeRowInto) çoktur optimize edilmiş (P-27/33/37/38/64/65/69/72/73/75, v3.19 grup fsync). Kalan boşluk **satır başına tekrar eden katmanlı işlerde**: çift varlık denetimi (Exists + Insert sondalaması), otomatik-PK çakışma okuması (satır başına tam KV okuma), IdxAddRow içindeki sözlük/dizi trafiği, batch dışı Insert'te satır başına sema kopyası ve SQL metin katmanının cümle/satır başına koordinasyon maliyeti. SQLite'a göre 2x'lik kapanma boşluğunun büyük bölümü ilk üç maddede toplanıyor.

| # | Bulgu | Dosya | Tahmini kazanç (tahmin) | Risk |
|---|-------|-------|--------------------------|------|
| B1 | PK varlık denetimi: çift hash sondalaması + CS | VDbTable + VDbBackendV3 | 0,8–1,8 µs/satır | orta |
| B2 | Oto-PK/IDENTITY çakışma taraması: satır başına ReadRow | VDbTable.pas | 0,5–1,5 µs/satır (oto-PK) | orta |
| B3 | IdxAddRow satır içi sözlük/dizi trafiği | VDbTable.pas | 0,4–1,5 µs/satır (indeksli) | düşük-orta |
| B4 | Batch dışı Insert: satır başına GetTable sema kopyası | VDbTable.pas | 0,2–0,6 µs/satır | düşük |
| B5 | CheckConstraints kolon/indeks tarama işleri | VDbTable.pas | 0,2–0,8 µs/satır | düşük |
| B6 | CheckFk: FK başına FindCol + VDbNorm | VDbTable.pas | 0,1–0,4 µs/satır/FK | düşük |
| B7 | SplitStatements genel yolu: karakter birleştirme + çift Trim + O(n²) dizi | VDbSql.pas | 1–3 µs/cümle (çok-cümleli metin) | düşük |
| B8 | ExecInsert RETURNING: satır başına O(kolon²) eşleme + O(n²) dizi | VDbExecutor.pas | 0,5–2 µs/satır (RETURNING) | düşük |
| B9 | Genel INSERT yolunda satır başına tetikleyici yoklaması | VDbExecutor + VDbTable | 0,3–1 µs/satır (genel yol) | düşük-orta |
| B10 | Plan önbelleği temizliklerinde AST sızıntısı + anahtar tahsisi | VDbSql.pas | dolaylı (uzun süreli degradasyon) | düşük |
| B11 | PutRow (PUT/UPDATE): satır başına tam okuma + deşifre, prefix önbelleksiz hash | VDbTable.pas | 0,5–1,5 µs/satır (UPDATE) | orta |
| B12 | Partial indeks: satır başına predicate metni yeniden ayrıştırma | VDbTable.pas | 0,5+ µs/satır (partial indeks) | orta |
| B13 | PutPtr: çift yazılabilirlik denetimi; overwrite'te ValBuf birikimi | VDbBackendV3.pas | küçük / bellek | düşük |
| B14 | Autocommit fsync sınırı (kanıt sınırlı — öneri mevcut mekanizmaları kullanmak) | VDbBackendV3 / VDbPageEngine | ~0,32 ms/commit (kanıt: kendi ölçüm notları) | — |

---

## B1 — PK varlık denetimi: her INSERT'te iki ayrı hash sondalaması + kritik bölüm

**Kanıt:**
- `VDbTable.pas:10592-10605` — `if not FSkipDupCheck then if FKvB.Exists(key) and FKvB.Get(key, b) then ...`
- `VDbTable.pas:10596-10597` — kod yorumu: *"Exists her satirda dosya kilidi aldigindan ~1,8 us tasarruf"* (SkipDupCheck=True iken).
- `VDbBackendV3.pas:2208-2248` (Exists) — batch'te `FBatchSet.Map.TryGetValue` (isabet), ama yeni anahtarda **miss** → `FEngCs.Enter` (2224) → `FSets.TryGetValue` (2232, ikinci sözlük araması) → `FEng.Contains` (2244, heap sondalaması).
- `VDbBackendV3.pas:1928` — hemen ardından `PutPtr → FEng.Insert(Key,...)` **aynı anahtar için ikinci sondalamayı** yapar (P-27 tek geçişli ekleme yalnız kendi içinde tekil).

**Maliyetin kaynağı:** Varlık denetimi (Exists) ve yazma (Insert) aynı bilgiyi ayrı ayrı arar; arada kritik bölüm gir/çık + iki TDictionary araması + iki FNV/dizi sondalaması yapılır. Tekil PK garantisi olan iş yükünde tamamen boştur.

**Öneri:** `PutPtr`/`FEng.Insert` "anahtar zaten vardı" bilgisini geri döndürsün; "duplicate PK" ile "hash çarpışması" sınıflandırması (DecodeRow) yalnız çakışma GERÇEKLEŞTİĞİNDE yapılsın. Batch içi "aynı partide yazıldı mı" kontrolü zaten `s.Map.TryGetValue` ile tek arama olur. Böylece satır başına: 1 kritik bölüm + 1 sözlük araması + 1 hash sondalaması kalkar.

**Tahmini kazanç:** 0,8–1,8 µs/satır (tahmin; üst sınır kendi ölçüm notlarına dayanır) → 6,39 µs/satır'ın ~%13–28'i.
**Risk:** Orta — hata sınıfı (duplicate PK / hash çarpışması) ve `FSkipDupCheck` sözleşmesi korunmalı; mevcut testlerde bu iki hata ayrımı doğrulanmalı.

---

## B2 — Otomatik PK / IDENTITY: satır başına tam KV okuma + deşifre

**Kanıt:**
- `VDbTable.pas:10563-10571` — PK boşsa: `iv := AutoIncOf(tp^) + 1; if ReadRow(tp^.Name, IntToStr(iv), dummyVals) then iv := MaxPkInt(tp^) + 1;` — **her oto-PK INSERT'ünde bir ReadRow** (hash + Get + DecodeRow → TStrArray tahsisi) + `IntToStr`; çakışma halinde `MaxPkInt` tam tablo taraması (`VDbTable.pas:7321`).
- `VDbTable.pas:6089-6095` (ApplyIdentity) — IDENTITY kolonunda aynı desen: `if (T.PkIndex = i) and ReadRow(T.Name, IntToStr(iv), dummy) then iv := MaxPkInt(T) + 1;` — satır başına.

**Maliyetin kaynağı:** Sayacın "eski dosyada geride kaldı" kendini-onarma denetimi her insert'te tekrarlanır; oysa bir kez doğrulansa (veya çakışma Insert'in False döndüğü duruma ertelense) yeterlidir.

**Öneri:** Sayaç doğrulaması için oturum/başlangıç başına tek seferlik "validated" bayrağı; veya doğrulamayı yalnız `BumpAutoInc` ilk kez çalıştığında/DB açılışında yap. Alternatif: `FEng.Insert` False dönerse `MaxPkInt` ile onar (çakışma nadir olduğu için masraf o yola kayar).

**Tahmini kazanç:** 0,5–1,5 µs/satır (tahmin) — yalnız oto-PK/IDENTITY'li tablolarda; açık PK verilen sıradan yükte etkisi yoktur.
**Risk:** Orta — sayacı geride kalmış eski DB'lerdeki kendini-onarma davranışı testlerle korunmalı.

---

## B3 — IdxAddRow: satır başına/индeks başına gereksiz sözlük yazması, doğrusal arama ve dizi tahsisi

**Kanıt (hepsi satır başına, indeks başına):**
- `VDbTable.pas:7801-7802` — `if FPkIdx.ContainsKey(T.TableId) then FPkIdxDirty.AddOrSetValue(T.TableId, True);` — her IdxAddRow çağrısında 1–2 sözlük işlemi.
- `VDbTable.pas:7823-7825` — `FIdxCtype.AddOrSetValue(k, ...)` — değer indeks ömrü boyunca **hiç değişmez**; yine de her satırda sözlük yazılıyor.
- `VDbTable.pas:7834` — `if FIdxDirty.IndexOf(k) < 0 then FIdxDirty.Add(k);` — **O(kirli liste) doğrusal tarama**, satır başına indeks başına. Aynı desen `7877` (IdxDelRow), `7902` (IdxAdd), `7927` (IdxDel).
- `VDbTable.pas:7808 → 7358-7374` (IdxKeyOfRow) → `8605-8615` (IdxColsOf) — **her çağrıda TIntArray tahsisi** (`Copy(...)` veya `SetLength(Result,1)`), satır başına indeks başına.
- `VDbTable.pas:2600-2628` (VDbIdxJoin) — çok kolonlu anahtar `Result := Result + IntToStr(...) + ':' + Vals[...]` (2626) — kolon başına birden fazla ara dize tahsisi (kareleme eğilimli).
- `VDbTable.pas:7819` — `op.Cov := VDbIdxJoin(Vals, T.Idx[j].Incl)` — INCLUDE boşken bile çağrı.

**Öneri:**
1. `FIdxCtype` indeks kurulumunda bir kez doldurulsun (CREATE INDEX/Load anı).
2. `FIdxDirty.IndexOf` yerine indeks konumu başına "kirli" bayrağı veya `TDictionary<Int64,Byte>`/kümе; veya `IndexOf` yalnız ilk eklemede (`l.Count = 0` iken) çalışsın.
3. `IdxKeyOfRow` tek kolonlu indeks için `T.Idx[j].Col`'ü doğrudan kullansın (dizi tahsisi yok); `VDbIdxJoin` için `T.Idx[j].Cols` referansı (kopyasız) + tek geçişli, kapasiteli anahtar tamponu.
4. `FPkIdx`/`FPkIdxDirty` kontrolü HasIdxWork önbelleğindeki gibi tablo başına önbelleklensin (P-65 deseni).

**Tahmini kazanç:** indeksli tabloda 0,4–1,5 µs/satır (tahmin; indeks sayısına ve kirli listeye göre), indekssiz tabloda ~0.
**Risk:** Düşük-orta — FIdxDirty sadeleştirme mantığı DropIdxPend/FlushIdxPending ile tutarlı olmalı.

---

## B4 — Batch dışı Insert: satır başına tam sema kopyası (GetTable)

**Kanıt:**
- `VDbTable.pas:10455-10458` — `FOpenTDef := GetTable(Table);` — `ATableDef = nil` ve batch dışı **her Insert çağrısında**.
- `VDbTable.pas:10322-10326` (GetTable) — `VDbNorm(Name)` + sözlük araması + **TTableDef kayıt dönüş kopyası**: Cols (her TColDef: Name/Def/… dize alanları), Idx, Fks, Checks (iç içe dinamik diziler) için yönetilen alan refcount trafiği — satır başına yüzlerce baytlık kayıt kopyası.
- Buna karşılık batch yolu `FBatchTableDef` ile önbellekli: `VDbTable.pas:10420-10424`.

**Öneri:** Batch dışındaki yol için de tek girdili sema önbelleği (ad + şema nesil/kirli sayacı) — P-55/P-26 mantığının genelleştirilmesi. Alternatif: ince API'de `ATableDef` zorunlu kılın (benchmark bunu zaten kullanabilir).

**Tahmini kazanç:** 0,2–0,6 µs/satır (tahmin).
**Risk:** Düşük — her DDL'de önbellek geçersizleştirme disiplini şart (mevcut FBatchTableCached bozma noktalarıyla aynı).

---

## B5 — CheckConstraints: satır başına kolon/indeks turlaması

**Kanıt:**
- `VDbTable.pas:6525` — her kolonda `if (T.PartType <> '') and (T.Cols[i].Name = T.PartCol)` — kolon başına dize karşılaştırması; parti kolon indeksi şemada bir kez hesaplanabilir (PutRow'daki `7092-7098` doğrusal araması da aynı).
- `VDbTable.pas:6507` — her INT/STR değerde `(Length(Vals[i]) = 4) and SameText(Vals[i], 'NULL')`.
- `VDbTable.pas:6576-6658` — her satırda `for i := 0 to High(T.Idx)` tam tur; UNIQUE bilesik denetiminde `6614` `icols := IdxColsOf(T, i)` (dizi tahsisi) + `6615` `ikey := VDbIdxJoin(...)` — satır başına UNIQUE indeks başına.
- `VDbTable.pas:6531` — `ik := IdxKey(T.TableId, i)` (aritmetik, ucuz) — kabul edilebilir.

**Öneri:** Parti kolon konumu ve "hangi indeksler UNIQUE" listesi şema tanımında derlensin (TTableDef'e ön hesaplı alan); bilesik UNIQUE anahtarı için satır içi yeniden kullanılan tampon; kolon döngüsünde dal sayısı azaltılabilir (Ctype'a göre tek çağrı).

**Tahmini kazanç:** 0,2–0,8 µs/satır (tahmin; kolon/indeks sayısına bağlı; UNIQUE indeksli tablolarda daha yüksek).
**Risk:** Düşük.

---

## B6 — CheckFk: her satır, her FK için FindCol + VDbNorm

**Kanıt:**
- `VDbTable.pas:7061-7075` — FK döngüsü: `VDbNorm(T.Fks[i].RefTable)` (7065), `rc := FindCol(rt, T.Fks[i].RefCol)` (7069) — **satır başına O(ref-kolon) tarama + VDbNorm tahsisi** (`FindCol`: `6458-6467`, kolon başına `T.Cols[i].Name = n` dize karşılaştırması), sonra `RefValueExists` (6661+) — PK'da ReadRow, indekssizse tam tarama.

**Öneri:** TFkDef içine çözülmüş `(RefTableId, RefColIdx)` — FK tanımı işlenirken bir kez (CREATE/LOAD/ALTER'da). `RefValueExists` için PK hedefinde ReadRow yerine `Exists` (değer okumaya gerek yok).

**Tahmini kazanç:** FK'lı tabloda 0,1–0,4 µs/satır/FK (tahmin).
**Risk:** Düşük — ALTER'da kolon sırası/değişimi yeniden çözümlemeyi tetiklemeli.

---

## B7 — SQL metin toplu çalıştırma: SplitStatements genel yolu

**Kanıt:**
- `VDbSql.pas:3004-3012` — her tanımlayıcı token'ı için `w := w + S[i]` **karakter karakter dize birleştirme** (her append yeni tahsis) + `w2 := UpperCase(w)` (bir tahsis daha). Kendi yorumları (`2920-2921`) bu desenin tek-ifade yolunda ~2,4 µs yediğini söylüyor; genel yol (çok-cümleli metin) hâlâ aynı deseni kullanıyor.
- `VDbSql.pas:3041-3044` — her cümle için `Trim(Copy(S, start, i-start))` **iki kez** (boşluk kontrolü + atama) → cümle başına 2 Copy + 2 Trim tahsisi.
- `VDbSql.pas:3043, 3052` — `SetLength(Result, Length(Result) + 1)` — N cümlede **O(n²) dizi kopyası**.

**Öneri:** (1) Tanımlayıcı taramasında başlangıç/bitiş indeksiyle tek `Copy` (birleştirme yok) ve yalnız `CompareText` ile anahtar kelime karşılaştırması (UpperCase tahsisi yok). (2) Sonuç dizisini katlayarak büyüt (kapasite alanı) ve tek `Copy`+tek `Trim`. (3) `Trim(Copy(...))` ifadesini bir kez hesapla.

**Tahmini kazanç:** tek Exec'te çok-cümleli metin partisinde 1–3 µs/cümle (tahmin). Not: tek cümlelik çağrılar P-20 hızlı yolundan (2922-2937) geçer, orada sorun yok.
**Risk:** Düşük — BEGIN/END blok sayacı, tırnak/yorum durumları birebir korunmalı (SplitStatements davranış testleri).

---

## B8 — ExecInsert: RETURNING'de satır başına O(kolon²) eşleme + O(n²) sonuç dizisi

**Kanıt:**
- `VDbExecutor.pas:15569-15579` — her satırda, her RETURNING kolonu için `for setIdx := 0 to High(cnames) do if SameText(cnames[setIdx], returningColNames[j])` — satır başına O(retKol × kolon) doğrusal arama. Fallback'te `FindColIdx` (`15617`, `15681`, `15718`, `15761`) aynı işi tekrarlar.
- `VDbExecutor.pas:15580-15581`, `15621-15622`, `15685-15686`, `15722-15723`, `15764-15765` — `SetLength(returningRows, Length(returningRows) + 1)` satır başına → **O(n²) kopya**.
- Ayrıca `15558-15583` (INSERT...SELECT) ve VALUES kollarının tamamında aynı desen.

**Öneri:** Kolon eşleme dizisini (`ci: array of Integer`) sorgu başına bir kez hesapla (isim listeleri döngüde değişmiyor); `returningRows` kapasitesini katlayarak büyüt (mevcut P-21 deseni).

**Tahmini kazanç:** RETURNING'li çok satırda 0,5–2 µs/satır (tahmin).
**Risk:** Düşük.

---

## B9 — Genel INSERT yolunda satır başına tetikleyici/RLS yoklaması

**Kanıt:**
- `VDbExecutor.pas:15561/15565` (INSERT...SELECT), `15731/15735` (VALUES, RETURNING'siz), `15706/15724` vb. — her satırda 2× `FireTriggers`.
- `VDbExecutor.pas:19344-19363` (FireTriggers) — her çağrıda `FT.TableExists` + `FT.GetTable` (TTableDef kayıt kopyası) + `FT.TriggersFor`.
- `VDbTable.pas:12278-12292` (TriggersFor) — tetikleyici sözlüğü boşsa erken çıkış iyi (12276-12277); ama **herhangi bir** tetikleyici varsa tüm sözlük taranır + `VDbNorm(TableName)` tahsisi — satır başına 2–4 kez.
- `VDbExecutor.pas:16177-16178` (ExecFastLiteralInsert) — cümle başına 2× TriggersFor (hızlı serit bunu zaten kapatıyor; genel yol açık).
- `VDbExecutor.pas:18637` (RlsRequireInsert) — `FT.RlsApplies` erken çıkışı var; RLS kapalıyken ucuz, ama çağrı + dizi atamaları satır başına sürüyor (`18639-18647` yalnız RLS açıkken).

**Öneri:** "Bu tabloda INSERT tetikleyicisi var mı" bayrağını şemada bir kez derle (mevcut FBatchHasIdentity deseni, `VDbTable.pas:10446-10453`); tetikleyici yoksa FireTriggers çağrılarını tamamen atlatacak tek kontrol. TriggersFor sonucunu tablo+timing+event için önbelleğe al veya isim listesini şemada sakla.

**Tahmini kazanç:** genel yolda 0,3–1 µs/satır (tahmin); hızlı literal seritte ~0.
**Risk:** Düşük-orta — tetikleyici ekleme/silme anında önbellek bozulmalı.

---

## B10 — Plan önbelleği: temizliklerde AST sızıntısı + cümle başına anahtar tahsisi

**Kanıt:**
- `VDbSql.pas:4311` — `if FPlanCache.Count >= PLAN_CACHE_CAP then FPlanCache.Clear;` — Clear **düğümleri Free etmiyor** (karşılaştır: `ClearPlanCache` `358-364` önce `pn.Free` yapıyor). Sınıra her ulaşımında tüm AST'ler + alt dize düğümleri bellekte kalır.
- `VDbSql.pas:4261` — `FPlanCache.Remove(cacheKey)` (StmtMutated) — çıkarılan düğüm de Free edilmiyor.
- `VDbSql.pas:4327` — DDL sonrası `FPlanCache.Clear` — aynı sızıntı.
- `VDbSql.pas:3145-3151 + 4229` — `PlanCacheKey` her çağrıda `Sql + #0 + IntToStr(...)` yeni dize üretir (arama için gereksiz tahsis; dizi/farklı uzunlukta hash kullanılabilir).

**Etki:** Uzun çalışan süreçte bellek büyümesi → allocator/önbellek baskısı → zamanla artan gecikme (ölçüm tabanındaki uzun partilerde görünür).
**Tahmini kazanç:** dolaylı; bellek baskılı iş yüklerinde ölçülebilir degradasyon önlenir (tahmin).
**Risk:** Düşük — sahiplik kuralı ("önbellekteki AST sahiplenilir") tek noktada toplanmalı.

---

## B11 — PutRow (PUT/UPDATE yolu): satır başına tam okuma + deşifre + hash tam yolu

**Kanıt:**
- `VDbTable.pas:7100` — `key := VDbHashKey(T.Name, Pk)` — Insert'teki P-56 prefix önbelleği (`10403-10418`) bu yolda **yok**; her satırda `VDbNorm(Table) + #0 + Pk` UTF8Encode + FNV (`1342-1357`).
- `VDbTable.pas:7101-7109` — `if FKvB.Get(key, oldB) then ... DecodeRow(oldB, ...)` — tam değer okuma + satır deşifresi **yalnız hash çarpışması sınıflandırması için**; eski değer PUT yolunda başka kullanılmıyor.
- `VDbTable.pas:7110` — `b := EncodeRow(...)` — sarmalayıcı her satırda yeni TBytes tahsis eder (`4124-4139`); `EncodeRowInto + PutPtr` (FEncBuf) deseni Insert'teki gibi (`10613-10619`) burada kullanılmıyor.
- `VDbTable.pas:7117` — `IdxAddRow(T, Vals, Pk, -1)` koşulsuz; Insert'teki `HasIdxWork` önbelleği (`10623`) burada yok.

**Öneri:** PutRow'a da P-55/P-65/P-56 desenlerini taşı: prefix önbelleği, FEncBuf+EncodeRowInto+PutPtr, çarpışma tespitini PutPtr dönüşüne erteleme (B1), HasIdxWork kapısı.

**Tahmini kazanç:** UPDATE/PUT ağırlıklı işlerde 0,5–1,5 µs/satır (tahmin); saf INSERT benchmarkında etkisi yok.
**Risk:** Orta — hash çarpışması tespiti korunmalı (B1 ile ortak çözüm).

---

## B12 — Partial indeks: satır başına predicate metni yeniden ayrıştırma

**Kanıt:**
- `VDbTable.pas:7807` (IdxAddRow), `7856` (IdxDelRow) — `VDbPredOK(T.Idx[j].Predicate, Vals, T.Cols)` satır başına indeks başına.
- `VDbTable.pas:2075-2337` (VDbPredOK) — her çağrıda predicate METNİ recursive-descent ile baştan ayrıştırılır; `Operand` içinde `SVal := SVal + S[P]` karakter birleştirme (`2137`, `2158`) — her atom için O(n) tahsis.
- Boş predicate erken çıkışı doğru (`2326-2329`): normal indeksler etkilenmiyor.

**Öneri:** Predicate'i indeks tanımında bir kez ayrıştırıp sembolik (AST) formda sakla; VDbPredOK ağacı doğrudan yürütsün. Karar metni aynı kalır.

**Tahmini kazanç:** partial indeksli tabloda 0,5+ µs/satır (tahmin).
**Risk:** Orta — metin yorumlayıcı ile sembolik yürütmenin sonuç eşitliği testlerle doğrulanmalı (NULL/UNKNOWN semantiği dahil, `1800-1829`).

---

## B13 — PutPtr: çift yazılabilirlik denetimi ve overwrite'te ValBuf birikimi (küçük)

**Kanıt:**
- `VDbBackendV3.pas:1880-1881` — `RequireWritable; RequireBatchWrite;` — ikincisi zaten birincisini çağırıyor (`1777-1782`); satır başına iki çağrı (ucuz ama gereksiz).
- `VDbBackendV3.pas:1895-1902` — aynı anahtar üst üste yazıldığında eski kayıt `s.Map`'te güncellenir ama **eski baytlar ValBuf'ta kalır**; `s.ValLen` her yazım kadar artar. UPDATE-ezici batch'lerde tampon O(toplam yazım) büyür (yalnız bellek; apply tek kayıt okur: `1679-1687`).

**Öneri:** (a) iç içe denetimi tek çağrıya indir. (b) Aynı anahtara art arda yazılan (overwrite) durumları: rec güncellenirken önceki uzunluk geri alınabilir (ValOff geri sarılır) veya `ValLen` toplamını sınırlayan boşaltma eşiği.

**Tahmini kazanç:** küçük (çağrı tasarrufu ~onlarca ns/satır, tahmin); asıl kazanç overwrite-ezici iş yüklerinde bellek.
**Risk:** Düşük — geri alma (savepoint journal) ValBuf offset'lerine dayanıyor (`3214-3231`); geri sarma noktası journal ile uyumlu olmalı.

---

## B14 — Autocommit / fsync sınırı (yalnız mevcut kanıtla)

**Kanıt (motor kendi ölçümlerini yorumlarda veriyor):**
- `VDbPageEngine.pas:866-885` — v3.19 GRUP COMMIT: tek fsync çok commit; *"tek fsync bedeli 0,32 ms"* (875).
- `VDbBackendV3.pas:3002-3037` — CommitBatch: WAL yaz (`CommitNoSync`) + kilit dışı `AwaitDurable`; fsync commit'in ~%60'ı.
- `VDbBackendV3.pas:3082-3098` — Flush: P-61 (boş Flush 1,76 µs → 0,01 µs) ve P-DUR v2 (`DurableOnFlush=False`: fsync checkpoint'e ertelenir, *"fsync ~360 us/islem"*).

**Değerlendirme:** Tek satır autocommit 0,38 ms/commit ≈ fsync (0,32–0,36 ms) baskın; motorda kalan ~0,02–0,06 ms. Yeni bir fsync penceresi önermiyorum (dayanıklılık riski, kanıt yok). Somut fırsatlar mevcut mekanizmaları kullanmakta: (a) tek-istemci senaryoda `DurableOnFlush=False` modunu varsayılan/önerilen yapmak (kod zaten destekliyor, `3107-3114`), (b) uygulama düzeyinde batch (bulk 1000 satır 1,916 ms/işlem ≈ 1,9 µs/satır commit amortisyonu — bu zaten iyi), (c) grup commit'in çok bağlantılı senaryoda açık kaldığından emin olmak.

**Tahmini kazanç:** autocommit'te fsync dışındaki kalan kısım <0,1 ms (tahmin); asıl kazanç uygulama davranışında (batch).
**Risk:** — (öneriler mevcut özellikleri kullanır).

---

## Düşük öncelik / gözlemler

- **EncodeRowInto** (`VDbTable.pas:3740-4122`) zaten çok optimize (P-17b/P-33/P-65). Kalan mikro-fırsatlar: `PutPkField`'ın INT kanonik kontrolü satır başına pk uzunluğu kadar tarama (`3907-3931`, ucuz); `IsPureAscii` taraması ile ana döngüdeki ASCII taramasının çift yapılması (`4092-4093` vs `3850-3856`) — yalnız non-ASCII yolda. Tahmini kazanç: <0,1 µs/satır (tahmin), öncelik düşük.
- **Nokta okuma ve tam tarama** ölçümleri (2,90 µs/sorgu; 75-86 ns/satır) zaten SQLite'ın önünde; bu raporda eylem yok. ReadRow'un `SetLength(Value,0)` + tam TBytes tahsisi (`VDbPageHeap.pas:1455-1507`) sözleşmeye bağlı; yalnız API genişletmesiyle (PByte çıkışı) iyileşir.
- **VDbPageHeap.Insert** (`1326-1377`) tek geçişli sondalama (P-27) + `PlaceCellKV` tek kopya (P-37/38/73/75) — depo katmanında satır başına belirgin bir artık maliyet görmedim. `PageMapRemove` O(sayfa anahtarı) (`419-432`) yalnız silme yolunda; silme-ezici yüklerde (UPDATE = sil+ekle) dikkat edilebilir (`VDbPageHeap.pas:1421-1437` UPDATE'in farklı boyut yolu DeleteAt+InsertRaw yapar).
- **ApplyBatch** (`VDbBackendV3.pas:1656-1764`) ve etiket koşucusu (P-69, `2677-2727`) satır başına optimize; ek öneri yok.

---

## Önerilen uygulama sırası (beklenen etkiye göre)

1. **B1** (varlık denetimini yazmayla birleştir) — en yüksek ölçülebilir kazanç; kendi notlarındaki 1,8 µs/satır bu kaleme ait.
2. **B3** (IdxAddRow sözlük/IndexOf/dizi tahsisleri) — indeksli benchmarklarda ikinci büyük kalem.
3. **B2** (oto-PK ReadRow taraması) — oto-PK/IDENTITY tablolarında büyük; diğerlerinde serbest.
4. **B4 + B5** (semа kopyası + CheckConstraints) — her INSERT'te küçük ama garantili tasarruf.
5. **B7 + B8** (SQL metin partisi + RETURNING) — SQL katmanı boşluğunu (12,22/7,62 → 6,39) kapatır.
6. **B9–B13** — yol/koşul özelinde; B10 (sızıntı) bakım amaçlı yapılmalı.

## Doğrulama önerisi (bu inceleme dışında)

Her madde için önce mevcut benchmarkın (tb.Insert 1M satır; multi-row VALUES; SQL text batch) A/B ölçümü alın; kazanç tahminleri bu raporda yalnız öngörüdür. B1/B2'de hata yolu testleri (duplicate PK, hash çarpışması, eski DB'de geride sayaç) ayrıca çalıştırılmalıdır.


---

# EK-F — Mimari, API, Kod Kalitesi ve Test Bosluklari

# DENETİM RAPORU — Mimari, API Tasarımı, Kod Kalitesi ve Test Boşlukları
**Hedef:** `D:\veritabani` (dal `v3`) — FPC 3.2.4 / Delphi modu / i386-win32
**Tarih:** 2026-11-06 · **Mod:** salt okunur (hiçbir dosya değiştirilmedi, derleme/çalıştırma yapılmadı)
**Kapsam:** VDbBackendApi, VDbFactory, VDbErr, VDbTable, VDbExecutor, VDbSql, VDbBackendV2/V3, VDbPageStore/VDbPageWal/VDbPageHeap, VDbChangeLog, tests/gates (17 birim), tests/sql/sqltest.lpr, .github/workflows/ci.yml

---

## 0. YÖNTEM VE GÜVENİLİRLİK NOTLARI

- **Kanıt standardı:** Her bulgu `dosya:satır` ile doğrulandı (grep + read ile satır birebir teyit edildi). Doğrulanamayan iddialar `ŞÜPHELİ` olarak işaretlendi.
- **HAREKETLİ HEDEF UYARISI (önemli):** İnceleme sırasında `VDbTable.pas` eşzamanlı olarak değiştirildi. Ölçülen boyut/zaman: `00:54 → 440.123 B`, `01:00 → 438.744 B`, `01:15 → 435.727 B`. İncelemenin ilk bölümünde çalışma ağacında olan **P-125** değişikliği (`VDbDecodeStreamRowPkP`, `VDbDecodeStreamRowExtP`'ye `PkColOut/Pk` çıkışları, `TVTableDb.ScanRowsPart`'in akışlı yeniden yazımı) raporun sonunda **geri alındı** (`git status` temiz, HEAD = `8b98b01`). Bu yüzden:
  - `VDbTable.pas` satır numaraları **06.11.2026 ~01:15 anlık görüntüsüne** göredir.
  - P-125'e ilişkin bulgular §7'de ayrı ve "geri alındı" damgasıyla verilmiştir.
- **Bri̇fi̇n doğrulanmayan iki iddiası düzeltildi** (bkz. §1 ve §6): (a) P-67 commit edilmiştir ve bayraklar **okunuyor**; (b) "hiçbir test koşulmadı" iddiası commit kayıtlarıyla çelişiyor — doğrusu aşağıda.

---

## 1. BULGULAR

### [YÜKSEK-1] Hata yönetimi parçalı: 7 istisna sınıfı, 3 farklı kodlama şeması
`VDbErr.pas:8-11` kuralı şunu vaat eder: *"yalnızca sınıf Exception → EVDbException olur ve kod eklenir … arayüz `on E: EVDbException` ile `E.ErrorCode` üzerinden programatik karar verebilir"*. Gerçeklik bu kuralı çiğniyor:

| Sınıf | Tanım | Kod | Kapsam |
|---|---|---|---|
| `EVDbException` | `VDbErr.pas:73` | `TVDbErrorCode` | VDbTable, VDbCore |
| `EVdbBackendV3` | `VDbBackendV3.pas:43` | YOK | v3 motorunun tüm hataları (40+ raise) |
| `EVdbBackendV2` | `VDbBackendV2.pas:21` | YOK | v2 adaptörü |
| `EVdbFactory` | `VDbFactory.pas:41` | YOK | giriş noktası |
| `EVdbBackendApi` | `VDbBackendApi.pas:342` | YOK | arayüz |
| `EVdbChangeLog` | `VDbChangeLog.pas:67` | YOK | değişim günlüğü |
| `EVdbCryptError` | `VDbCrypt.pas:42` | kendi kodu (`VDB_CRYPTO_ERR`) | kripto |
| `Exception` (ham) | — | YOK | `VDbArrow.pas:864-1404`, `VDbParquet.pas:288-1292`, `VDbClient.pas:368-433`, `VDbMigrate.pas:196` |

**En somut sözleşme ihlali — aynı koşul, iki farklı istisna:**
- `VDbTable.pas:6351` → `raise EVDbException.CreateFmt(ecDuplicateSavepoint, 'savepoint zaten var: %s', ...)`
- `VDbBackendV3.pas:3242` → `raise EVdbBackendV3.CreateFmt('savepoint zaten var: %s', ...)` (kodsuz)
- Arayüz dokümanı ise açıkça `EVDbException ecDuplicateSavepoint` vaat eder: `VDbBackendApi.pas:148-150`.

**Zincirleme etki:** `VDbPgWire.pas:647-648` SQLSTATE eşlemesi (`ecDuplicateSavepoint → '3B001'`, `ecSavepointNotFound → '3B000'`) yalnız kodlu istisnalarda çalışır; v3 backend'inden fırlayan hata bu eşlemeye düşmez, protokol istemcisi genel hata kodu alır. Aynı şekilde `VDbFactory` hataları (`ecDatabaseNotFound`, `ecDatabaseLocked`, `ecCorrupt` tanımlıyken) kodsuzdur; uygulama giriş noktasında programatik ayırım yapamaz.

### [YÜKSEK-2] Doğrulama borcu — düzeltilmiş çerçeve (iddia kısmen çürütüldü)
Görev brifingi "30 commit, hiçbir test koşulmadı" diyordu. Kanıtlar bunu **çürütüyor**, ama gerçek ve kalan bir borç var:

**Çürüten kanıt (commit içi kayıt):**
- `e24990d` (05.11): *"Doğrulama: sqltest 3287/0/0, wherenull TEMIZ, chainnull TEMIZ"* — P-90..P-121 arası ~20 commit'te aynı kayıt tekrarlanıyor.
- `28ed76f` (02.11): *"WSL/Ubuntu-22.04 sonuc: 20/20 kapi gecti (pagechk, storechk, heapchk, crashtest, dropchk x3, idxchk, backendchk, v3sqlchk, migchk, factorychk, logchk, pitrchk, btreechk, replchk, lockchk, snapchk, prochk, sqltest)"*.
- P-50..P-67 arası her commit mesajında `sqltest: 2885 gecti / 0 kaldi / 33 atlandi` kaydı var (`f0ed539`, `3ca6d5b`, `2d6d17f`, `6ab723c`, `2512759`, `57f1e1a`, `201e9e7`).

**Kalan gerçek borç:**
1. **HEAD (`8b98b01`, 05.11 23:17) test kaydı içermeyen tek commit.** Mesajda panel/srv.log/`/api/yavas` işi anlatılıyor ama `Doğrulama:` satırı yok; ayrıca mesaj `mtakip/` (gitignore'lu, repoda olmayan — `.gitignore:63`) projesindeki işi anlatıyor, commit'in kendisi yalnız `VDbExecutor.pas` (+14/-2). Mesaj ≠ içerik.
2. **İnceleme sırasında yazılan P-125 kanıtsızdı** (§7) ve geri alındı.
3. **Derleme izleri güncel ağacı kapsamıyor:** `tests/gates/*.exe` = 02.11 07:26–08:12; `tests/sql/sqltest.exe` = 05.11 11:00. Bunlardan **sonra** değişen kaynaklar: `VDbTable.pas` (06.11), `VDbExecutor.pas` (05.11 22:23), `VDbCore.pas` (05.11 02:20), `VDbMM.pas` (05.11 11:51), `VDbSql.pas`/`VDbCrypt.pas`/`VDbBTree.pas`/`VDbPool.pas`/`VDbClientNet.pas`/`VDbTimeTravel.pas` (04.11), `VDbPageStore.pas`/`VDbSync.pas`/`VDbIdxFile.pas` (02.11 11:33). (Not: kapılar `runall.sh` ile ayrı dizine derlendiğinden `.exe` izleri kesin kanıt değil, **destekleyici** kanıttır → bu alt madde `ŞÜPHELİ` bileşenlidir.)
4. Commit kayıtları **öz-bildirimdir**; CI artefaktları bu incelemede doğrulanmadı.

### [YÜKSEK-3] `StoreGenStamp`: dokümante edilmiş özellik hiç bağlı değil (ölü API + eksik davranış)
- Arayüz: `VDbBackendApi.pas:138-142` — *"bu oturumun gördüğü son commit sayacı … Sema katmanı bunu kullanarak FTables'i yeniden yükler (v3.18: süreçler arası DDL)"*.
- Uygulama: `VDbBackendV3.pas:3143`, `VDbBackendV2.pas:314`.
- **Çağrı yeri: TÜM AĞAÇTA YOK** (yalnız tanım/uygulama satırları). Yani "çok süreçli DDL tazelik" mekanizması hiç çalışmıyor; `VDbTable.ReloadSchema` (`VDbTable.pas:6411`) yalnız sunucu tarafı tetiklerle çağrılıyor (`VDbExecutor.pas:20389, 20432, 20580, 20631`).

### [YÜKSEK-4] P-58 optimizasyonlarının ikisi de erişilemez: `BeginWrite/EndWrite` ve `ExclusiveAccess`
- `IVDbBackend.BeginWrite/EndWrite` (`VDbBackendApi.pas:125-131`, "Tek INSERT + Flush yolunda 4 dosya kilidi syscall'ından 2'ye düşer"): **hiçbir yerden çağrılmıyor.** Tek "kullanım" `VDbTable.pas:5260/5266` — oradaki `FLock.BeginWrite/EndWrite` **başka bir nesne** (TMREW kilidi, `VDbSync`). Geriye kalanlar tanım/uygulama satırları (`VDbBackendV2.pas:293/298`, `VDbBackendV3.pas:3128/3133`). → Ölü API + uygulanmamış optimizasyon.
- `ExclusiveAccess` (P-58c/P-60): `VDbTable.pas:5259-5277` MREW kilidini atlıyor, `VDbPageStore.pas:1284, 1486, 1547, 1581, 1611` dosya kilitlerini atlıyor — ama **hiçbir kod yolu bunu `True` yapmıyor** (set eden yalnız `VDbBackendV3.pas:3432` uygulaması; üretim kodunda/tektestlerde çağrı yok). Yani kilit atlayan tehlikeli yol erişilemez + sınanmamış.

### [ORTA-1] Test boşlukları — sıfır kapsamlı API yolları
`tests/gates/*.lpr` + `tests/sql/sqltest.lpr` içinde adı/geçeni **hiç bulunmayan** (isim + davranış taraması) yüzeyler:

| Yol | İlgili değişiklik | Kapsam |
|---|---|---|
| `ExclusiveAccess` (tek süreçli kilit atlama) | P-58c, P-59/P-60 | YOK |
| `DurableOnFlush` (fsync erteleme, P-DUR) | `VDbBackendApi.pas:182-188` | YOK |
| `BeginWrite`/`EndWrite` | P-58b | YOK (API zaten ölü) |
| `StoreGenStamp` | v3.18 | YOK |
| `WaitForeignTxn`, `RefreshBatchSnapshot` | `VDbBackendApi.pas:197-200` | YOK (yalnız `VDbSql.pas:3170-3914`) |
| WAL sürüm 1 → 2 geriye dönük uyum (`VDB_WAL_VER_COMPAT`), `WalCrc` başlık-only CRC | P-52/P-53 | YOK (`tests/` içinde `VDB_WAL_VER`/`WalCrc` geçmiyor; `pagechk.lpr:308-390` yalnız `PageSeal`'i çağırıyor) |
| `VDbMM` (özel bellek yöneticisi, P-110) | 05.11 | YOK (kapı/sqltest uses'inde yok) |
| `VDbPool`, `VDbCdc`, `VDbDataSet`, `VDbTimeTravel` | — | YOK |
| `VDbArrow`/`VDbParquet`/`VDbXml`/`VDbVector` | — | doğrudan test yok (yalnız `VDbExecutor` içinden dolaylı) |

**P-50..P-67 değişen yolların kapıyla eşleşmesi:**

| Değişen birim/yol | Sınayan test | Not |
|---|---|---|
| `VDbTable` (INSERT, P-55/56/63/64/67) | `v3sqlchk`, `sqltest` (M10 IDENTITY/GENERATED: `sqltest.lpr:11121-11311`), `dropchk`, `migchk` | davranışsal kapsama var |
| `VDbExecutor` (P-51, P-58/59 SQL INSERT sarmalayıcı) | **yalnız `sqltest`** (hiçbir kapı `uses` etmiyor) | tek noktaya bağımlı |
| `VDbChangeLog` (P-68 `AddPutPtr`, P-69 `FlushTagRun`) | `logchk` (43 kontrol), `replchk`, `v3sqlchk` | iyi |
| `VDbPageStore` (P-54 `TxnPages`, P-57 `FAtEnd`, P-61 `FDirty`/`FWrittenBytes`) | `storechk`, `crashtest`, `heapchk`, `idxchk`, `lockchk` | dolaylı; `FAtEnd`/`FWrittenBytes` için hedef test yok |
| `VDbPageWal` (P-52/P-53 WAL v2) | `crashtest`, `idxchk` | sürüm uyum testi yok |
| `VDbPageHeap` (P-64 `PageMapAdd`) | `heapchk` | büyüme + `ReindexPages` için hedef test yok |
| `VDbSql` (P-51 `SplitStatements`) | `sqltest` (`sqltest.lpr:8856`, T45_F1) | iyi |
| `VDbBackendV2` | yalnız `migchk` | — |

### [ORTA-2] `runall.sh` ↔ `ci.yml` kapsam tutarsızlığı ("aynı tablo" iddiası yanlış)
- `tests/gates/runall.sh:12-13`: *"Kapılar ve beklenen çıktılar .github/workflows/ci.yml ile aynı tablodan gelir; yeni kapı eklenince İKİSİ güncellenmelidir."*
- **Fark 1:** `runall.sh:132` sqltest'i yalnız `--backend=v3` ile koşuyor. `ci.yml` sqltest'i **iki kez** koşuyor: v2 (`ci.yml:392-405`) + v3 (`ci.yml:407-431`). → runall (Linux/macOS CI job'ları `ci.yml:559-568, 581-590` bunu kullanıyor) **v2 SQL paketini hiç koşmuyor**.
- **Fark 2:** `ci.yml:212-247` `vdbmig` CLI kapısını koşuyor; runall'da yok. `ci.yml:54-60` 18 proje derliyor, runall 17.
- **Fark 3 (sessiz yeşil riski):** v3 koşusunda **33 test atlanıyor** (`sqltest v3 2885/0/33` — commit kayıtları). `runall.sh` "kalan=0" + "TUM SQL TESTLERI GECTI" dışında `atlanan` sayısını denetlemiyor; `ci.yml:428-431` yalnız sayının **raporlandığını** denetliyor, sıfır olmasını değil. Atlama sayısı bir eşik olarak izlenmiyor → yeni atlanan testler sessizce geçer.

### [ORTA-3] VDbFactory API tutarsızlıkları (parametre sırası, varsayılanlar, hata biçimi)
Beş giriş noktası aynı üç parametreyi farklı sırada/varsayılanla alıyor:

| Fonksiyon | İmza | Sorun |
|---|---|---|
| `VdbOpen` | `VDbFactory.pas:65-67` | `(CreateIfMissing, AllowV2, PoolPages)` |
| `VdbOpenOrCreate` | `:71-72` | `(PoolPages)` |
| `VdbOpenReadOnly` | `:80-81` | `(PoolPages, BusyMs=0)` — **PoolPages önce** |
| `VdbOpenWithBusyTimeout` | `:85-86` | `(BusyMs, CreateIfMissing, PoolPages)` — **BusyMs önce, varsayılanı yok** |
| `VdbOpenWithPassword` | `:90-92` | `(CreateIfMissing, PoolPages, BusyMs=VDB_DEF_BUSY_MS)` — **BusyMs sonda** |

- `BusyMs` aynı anlama gelirken üç farklı sözleşme: zorunlu / `=0` / `=VDB_DEF_BUSY_MS`. `VDB_DEF_BUSY_MS = 0` (`VDbPageStore.pas:63`).
- "Varsayılan kullan" temsili de iki türlü: Factory'de `PoolPages=0` iken motor kurucularında `APoolPages=VDB_DEF_POOL` (`VDbBackendV3.pas:497-518`, `VDbPageStore.pas:306`).
- Hatalar kodsuz `EVdbFactory` (`VDbFactory.pas:41`); oysa `VDbErr.pas:26-32`'de tam karşılıkları var.
- **Tutarsız tanı:** aynı "dosya tanınamadı/kitli" durumu `VdbOpen`'da hata (`:217-220`), `VdbOpenWithBusyTimeout`'ta sessiz geçiş (`:259-267`, `fam=vdfUnknown` → `Create(file_, False, …)`), `VdbOpenWithPassword`'ta aynı (`:281-290`).
- **Kilit yarışı:** `VdbOpenReadOnly` bilerek `VdbFamilyOfFile` çağırmaz — gerekçe yazılı (`:238-242`: "yazar tam aralık kilidi tuttuğunda bu okuma başarısız olur ve 'Veritabani yok' gibi YANLIŞ teşhis üretir"). Ama `VdbOpenWithBusyTimeout` (`:258`) ve `VdbOpenWithPassword` (`:280`) tam da aynı riskli yolu kullanır.
- `VdbResolveFile` (`:99-113`): `.odb` uzantılı olmayan var olmayan yol sessizce **dizine** çevrilir (`'mydb.foo'` → `'mydb.foo\veritabani.odb'`) — yazım hatasında şaşırtıcı "Veritabani yok" hatası.

### [ORTA-4] Katmanlama: ana tablo birimi hâlâ v2 çekirdeğine bağlı
- Hedef: *"tek giriş noktası VDbFactory olmalı; yeni uygulamalar TVDb bilmemeli (v2 legacy read-only ağaçta)"*.
- Ama `VDbTable.pas:15-17` interface uses'inde `VDbCore` + `VDbBackendV2` var; `TVTableDb.Create(AKv: TVDb)` v2 çekirdeğini sarıyor (`VDbTable.pas:5147-5151`: `FKvB := TVDbBackendV2.Create(FKv)`). Dolayısıyla `VDbTable`'ı kullanan her birim (VDbSql, VDbExecutor, VDbPgWire, VDbPool…) `VDbCore`/`TVDb`'yi de link eder.
- **İyi örnek (kanıt hedefin uygulanabildiğine):** `yonetim/hadmain.pas:67-70, 1389-1401` — *"Somut TVDb tipi GEÇMEZ; giriş noktası VDbFactory'dir"* + `VdbOpen(FilePath, FBe); FTb := TVTableDb.CreateBackend(FBe);`. (Not: `yonetim/hadmain.pas.backup` hâlâ eski `FKv: TVDb` yolunu içeriyor — ölü kopya, `hadmain.pas.backup:65, 1300-1303`.)
- Testlerde de fabrika atlanıyor: `lockchk.lpr` 15+ yerde `TVdbBackendV3.Create(...)` (`:309, :341, :506, :610, :633, :674, :695, :751, :878, :923, :942, :969, :998`). Beyaz kutu olabilir; ancak "tek giriş noktası" sözleşmesi bu yolla sınanmıyor (`factorychk` ayrı ve dar).

### [ORTA-5] `IVDbBackend` Boolean/çıktı sözleşmeleri tutarsız
Tek arayüzde en az **5 farklı Boolean anlamı**:
- `Delete: Boolean` = silindi mi (`VDbBackendApi.pas:82`), `Get: Boolean` = bulundu mu (`:81`)
- `RollbackToSavepoint/ReleaseSavepoint: Boolean` = "False: yok" (`:156-157`) — ama `Savepoint` aynı durumda **istisna** fırlatır (`:148-150`)
- `ScanRawIterAll: Boolean` = tarama erken kesildi mi (`:89-90`, `VDbBackendV3.pas:2573/2585/2606`)
- `AutoCompact: Boolean` = "eşik aşıldı da çalıştı mı" (`:250-252`)
- `LogSupported/ReplSupported/LogPrune/Verify/ScanAllAt/ReplAppendGroup` = destek/başarı
Hata biçimi de üç ayrı: `Boolean`, `Boolean + out AErr: string` (`LogPrune :312-313`, `ReplAppendGroup :336`), `out Report: string` (`Verify :220`), `string` döndürme (`LogStatus :274`), son-hata özelliği (`LastLogPruneError :314`, `LastAutoCompactError :249`). `LogPrune` hem `AErr` hem `LastLogPruneError` dolduruyor (çift kanal). İsimlendirme de dağınık: `GetInBatch`/`InBatch` (`:132-133`) Get*-deseni iken `LogSupported`/`ReplSupported`/`Count`/`CountTable` (`:84, :103, :272, :330`) düz fonksiyon; `Count: Integer` vs `CountTable: Int64` (`:84, :103`) farklı genişlikte.

### [ORTA-6] `VDbExecutor` interface uses şişkinliği (27 birim) + yeniden dışa açılma
- `VDbExecutor.pas:24-29`: interface uses 27 birim — `VDbArrow, VDbParquet, VDbXml, VDbVector, VDbSpatial, VDbReplication, VDbReplV3, VDbChangeLog, VDbMonitor, VDbCost, VDbExtension, VDbPlatform, VDbTrace…` Bu birimlerin çoğu yalnız implementasyonda gerekli olabilecek türden.
- `VDbSql.pas:24` bunu **kendi interface'inde** yeniden açıyor → `VDbSql` kullanan her birim (VDbPgWire, VDbPool, VDbDataSet, VDbTimeTravel, VDbSqlServer, sqltest) bu yığını miras alır.
- **Dairesel bağımlılık: YOK.** Tüm `*.pas` uses grafiği (interface+implementation, aşırı yaklaşımlı) tarandı — döngü bulunamadı. Bu iyi; sorun yalnız genişlik.
- **Bayat yorum:** `VDbExecutor.pas:46-49` *"VDbTable'in implementation uses'i VDbExecutor olduğu için …"* — artık yanlış: `VDbTable.pas:1082-1084` yalnız `VDbMM, VDbSync, VDbParallel` içeriyor. `VDbTable.pas:23`'teki `PDummy = ^Integer; // dummy to satisfy type section` hack'i de tip bölümünü açık bırakmak için duruyor.

### [DÜŞÜK-1] Sihirli sayılar
- `VDbPageCrypto.pas:33` `VDB_ENC_ENVELOPE = VDB_ENC_NONCE_LEN + 4096 + VDB_ENC_TAG_LEN`; ayrıca `:136, :137, :146, :147, :161, :164-165` — sayfa boyu **hard-code 4096**, `VDB_PAGE_SIZE` (`VDbPage.pas:31`) kullanılmıyor (birim `VDbPage`'i kullanmıyor; katmanlama yüzünden).
- `VDbExecutor.pas:13765` `zBCount := Integer(FT.Backend.DataFileSize div 4096) + 64;`
- `VDbIdxFile.pas:228, :376` `Hdr.PageSize = 4096`.
- `VDbPageWal.pas:677, :689, :812, :831` — `WalCrc(..., 16, ...)` çağrısında başlık uzunluğu **literal 16**, oysa `VDB_WAL_REC_HDR` sabiti aynı dosyada mevcut (`:679`'da kullanılıyor) — aynı dosyada iki üslup.
- Olumlu istisna: `VDbPageStore.pas` sayfa boyunu tutarlı biçimde `VDB_PAGE_SIZE` ile kullanıyor (ör. `:555, :801-848, :2106`).

### [DÜŞÜK-2] Yinelenen kod blokları
- **P-67 bayrak kurma döngüsü 3 kez kopyalanmış** (aynı 4 satır): `VDbTable.pas:10410-10415`, `:10447-10452`, `:10465-10470` (`FBatchHasIdentity/FBatchHasGenerated` sıfırla + tara). Tek yardımcı ile birleşebilir.
- `ResetBatchTableCache` (`VDbTable.pas:6362` bölgesinde, gövde `:6404-6419` anlık görüntüsü) 7 farklı yerden çağrılıyor (`:5211, :6373, :6445, :6452, :6472, :6495` + `ReloadSchema`) — çağrı disiplini elle; unutulursa bayat önbellek riski (aşağıda).
- hata-üretim blokları (`ecCorrupt` / `ecHashCollision` mesajları) farklı tarama yollarında birebir kopyalanıyor (ör. `VDbTable` içinde ScanRowsPart ve komşu tarama yardımcıları).

### [DÜŞÜK-3] Türkçe/İngilizce yorum karışıklığı + UTF-8 bozulması (mojibake)
Aynı dosya içinde üç farklı yorum üslubu: saf-ASCII Türkçe ("tekillestirme"), doğru UTF-8 Türkçe ("için"), ve **çift kodlanmış bozuk** Türkçe (`iÃ§in`, `Ã¶rn.`, `gÃ¶rÃ¼len`, `â€”`). Örnekler:
- `VDbExecutor.pas:32-33, 174, 189, 752, 2709-2710, 14462, 15202`
- `VDbSql.pas:161, 318, 2963`
- `VDbTable.pas:33, 173-174, 1036, 7157-7159, 9967, 10252, 11603-11604`
- `vdbapi_core.pas:14`
Ayrıca İngilizce yorumlar da dağınık: `VDbTable.pas:20-21` (İngilizce) + `:21-22` (Türkçe) yan yana. Kod tanımlayıcıları İngilizce, yorumlar ağırlıkla Türkçe — bu bilinçli olabilir; asıl sorun **bozuk kodlama** (okunamayan yorum) ve tutarsızlıktır.

### [DÜŞÜK-4] Derleme artefaktları kaynak ağacında
- Kök dizinde derlenmiş assembly çıktıları: `VDbBackendApi.s`, `VDbCrc32.s`, `VDbErr.s`, `VDbSync.s`, `VDbTypes.s` (03.11) — derleme yan ürünü, kaynak değil.
- `tests/gates/*.exe` (16 dosya, ~80 MB), `tests/sql/*.o/*.ppu`, `tests/bench/` altında birikmiş çıktı dizinleri (`p106s1/`, `p110s1..3/`, `p111sql*/`, `hello2`, `joindiag`, `sp2test`…).
- `yonetim/hadmain.pas.backup` — repoda tutulan eski kopya (§ORTA-4).
- `git status`: takip edilmeyen `chainnull/`, `wherenull/`, `tests/bench/*` çıktıları, `sıkıntı.md` (dosya adı UTF-8 bozuk: `s\304\261z\304\261nt\304\261.md`).

### [BİLGİ-1] Bri̇fin "P-67 ölü kod" iddiası ÇÜRÜTÜLDÜ
- `FBatchHasIdentity`/`FBatchHasGenerated` **dolduruluyor VE okunuyor**:
  - Alanlar: `VDbTable.pas:387-388`
  - Kurulum (3 yol): `:10410-10415` (batch), `:10447-10452` (FBatchTableDef), `:10465-10470` (FOpenTDef, non-batch)
  - **Okuma:** `VDbTable.pas:10539` `if FBatchHasIdentity then ApplyIdentity(tp^, vals);` ve `:10542` `if FBatchHasGenerated then VDbApplyGenerated(tp^, vals);`
  - Sıfırlama: `ResetBatchTableCache` içinde `:6374-6375`
  - Commit: `f0ed539` (31.10, P-67) — "commit edilmemiş" değil.
- Davranışsal test de var: `sqltest.lpr:11121-11311` (M10 IDENTITY/GENERATED).
- **Kalan risk (ORTA eşiğinde, doğrulanamadı → ŞÜPHELİ):** non-batch yolda bayraklar yalnız `FPrefixCacheName <> FOpenTDef.Name` olduğunda yeniden hesaplanıyor (`:10451` bölgesi). `ResetBatchTableCache` bayrakları sıfırladığı için normal yollar korumalı; ancak `LoadSchema` (`VDbTable.pas:5286`) bayrakları **sıfırlamıyor** ve `StoreGenStamp` (§YÜKSEK-3) hiç kullanılmadığı için başka sürecin DDL'i ile sema tazelenirse aynı tablo adında identity/generated eklenmiş olması bayrakların bayat kalmasına yol açabilir (identity kolonu sessizce boş kalır). Senaryo doğrulanamadı.

### [BİLGİ-2] Küçük notlar
- `VDbBackendApi.pas:339-344`: `TVdbBackendKvStore`'u anlatan yorum bloğunun arasına `EVdbBackendApi` sınıfı sıkışmış — yorum/sınıf eşleşmesi bozuk.
- `VDbBackendApi.pas:37` `TVDbRowTagFunc` vs `:57` `TVdbSessionIdFunc` vs `:72` `IVDbBackend` vs `:344` `TVdbBackendKvStore` — `VDb`/`Vdb` büyük-küçük harf üslubu tutarsız (Pascal'da etkisiz, okunurluk sorunu).
- `IVDbKvStore.ScanAll` (`:65-66`) varsayılan parametresiz, `IVDbBackend.ScanAll` (`:87-88`) `TableFilter: Integer = -1` — iki arayüzde farklı sözleşme (arayüzlerde varsayılan parametre, statik tipe göre çözüldüğü için tehlikeli desen).

---

## 2. SİHİRLİ SAYI / OKUNURLUK ÖZETİ
Yukarıdaki `DÜŞÜK-1` ve `DÜŞÜK-3` maddeleri. Ek olarak olumlu bulgu: `VDbErr.pas` hata kataloğu özenli (`VDbErrorName` case-bazlı, `VDbErr.pas:99-145`), yorumlarda tarih/etiket disiplini (P-xx, R-xx, F-xx, M10) izlenebilirlik sağlıyor.

## 3. DAİRESEL BAĞIMLILIK SONUCU
`*.pas` birimlerinin uses grafiği (interface + implementation, aşırı yaklaşımlı) çıkarılıp döngü arandı: **döngü yok.** Katman sırası genel olarak korunuyor (`VDbErr` → `VDbTypes` → `VDbCore`/`VDbBackendApi` → `VDbTable` → `VDbExecutor` → `VDbSql`). Tek mimari sitem: `VDbTable`'ın `VDbCore`/`VDbBackendV2` interface bağı (§ORTA-4) ve `VDbExecutor`/`VDbSql` uses genişliği (§ORTA-6).

## 4. TEST KAPSAMI HARİTASI (birim → kapı)
| Birim | Kapılar |
|---|---|
| VDbPage | pagechk |
| VDbPageStore | storechk, crashtest, heapchk, idxchk, lockchk |
| VDbPageHeap | heapchk, crashtest, idxchk |
| VDbPageWal | crashtest, idxchk |
| VDbPageEngine | crashtest, idxchk, lockchk, pitrchk, v3sqlchk |
| VDbChangeLog | logchk, replchk, v3sqlchk |
| VDbReplV3 | replchk |
| VDbSkipList/VDbBTree | btreechk |
| VDbIdxFile | idxchk |
| VDbBackendV3 | backendchk, dropchk, factorychk, lockchk, migchk, pitrchk, prochk, replchk, snapchk, v3sqlchk |
| VDbBackendV2 | migchk |
| VDbTable/VDbSql | dropchk, migchk, v3sqlchk, sqltest |
| VDbExecutor | **yalnız sqltest** |
| VDbSync | crashtest, sqltest |
| VDbCrc32/VDbCrypt/VDbKdf | sqltest, idxchk |
| VDbPgWire/VDbTls/VDbNet/VDbMetricsHttp/VDbClientNet/VDbSqlServer/VDbMonitor | yalnız sqltest (kullanım düzeyi belirsiz) |
| VDbMM, VDbPool, VDbCdc, VDbDataSet, VDbTimeTravel, VDbParallel*, VDbArrow, VDbParquet, VDbXml, VDbVector | **kapı yok** (*sqltest uses'te var, davranış kapsamı belirsiz → ŞÜPHELİ) |

## 5. ÖNERİ ÖNCELİĞİ
1. **[YÜKSEK-1]** Tüm `EVdb*` istisnalarını `EVDbException`'a bağla (en azından `ErrorCode: TVDbErrorCode` alanı) veya `VDbErr.pas` kuralını güncelle; `VDbBackendV3.Savepoint`'i `ecDuplicateSavepoint` ile fırlat (VDbBackendApi:148-150 sözü).
2. **[YÜKSEK-3]** `StoreGenStamp`'i sema tazeleme yoluna bağla ya da arayüzden/dokümantasyondan kaldır (sahte özellik).
3. **[YÜKSEK-4]** `BeginWrite/EndWrite`'ı INSERT/Flush yoluna gerçekten bağla ya da API'den çıkar; `ExclusiveAccess` için en az bir kapı (tek süreç + kilit atlama) yaz.
4. **[ORTA-2]** `runall.sh`'a v2 sqltest + vdbmig kapısını ekle; `atlanan` sayısını eşik yap.
5. **[ORTA-1]** §1 tablosundaki sıfır-kapsamlı yollar için kapı ekle (öncelik: WAL v1→v2 uyumu, DurableOnFlush, ExclusiveAccess, VDbMM).
6. **[ORTA-3]** `VdbOpen*` imzalarını tek şemaya oturt (ör. hep `(…, PoolPages, BusyMs)`), `EVdbFactory`'ye kod ekle.
7. **[ORTA-5/6]** `IVDbBackend` sonuç sözleşmesini sadeleştir (hata: `out AErr` **veya** istisna — ikisi değil); `VDbExecutor` interface uses'ini implementasyona indir.
8. **[DÜŞÜK]** 4096/16 sabitlerini `VDB_PAGE_SIZE`/`VDB_WAL_REC_HDR` ile değiştir; mojibake yorumları düzelt; `.s/.exe/.o/.backup` artefaktlarını temizle/gitingnore'la.

---
*Bu rapor salt okunur inceleme sonucu üretilmiştir; hiçbir kaynak dosya değiştirilmemiş, hiçbir derleme/çalıştırma yapılmamıştır. Satır numaraları §0'daki anlık görüntü uyarısına tabidir.*
