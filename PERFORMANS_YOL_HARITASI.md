# VDb — SQLite'dan Yavaş: Kök Neden Analizi ve Performans Yol Haritası

**Tarih:** Ekim 2026  
**Temel:** Kaynak kod tam tarama — `VDbCore.pas`, `VDbTable.pas`, `VDbSql.pas`, `VDbExecutor.pas`, `VDbPool.pas`  
**Hedef:** Aynı iş yükünde VDb'yi SQLite'a yaklaştırmak ya da geçmek.

> [!IMPORTANT]
> Bu belge **yeni özellik eklemez**. Mevcut kodun içindeki algoritmik maliyetleri hedef alır.  
> Her değişiklik ayrı commit, ayrı benchmark. Test geçmeden sonraki adıma geçilmez.

---

## Hızlı Özet — Neden Yavaş?

SQLite, bir sorgu çalıştırırken:
1. Dosyayı **sayfalar halinde** önbelleğe alır (page cache).
2. İstenen sayfayı bir kez okur, defalarca kullanır.
3. Sorgular **derlenir** ve tekrar çağrıldığında yeniden ayrıştırılmaz.
4. Tam tarama yerine **B-tree indeksi** ile doğrudan satıra atlar.

VDb şu anda bunların çoğunu yapamıyor ya da hatalı yapıyor. **7 somut kök neden** aşağıda.

---

## Yol Haritası Genel Bakış

```
┌─────────────────────────────────────────────────────────────┐
│  P0 — Acil (bu hafta): Dosya I/O ve Tarama Sorunları       │
│       KR-1: Tüm veritabanı yerine sadece hedef tabloyu tara │
│       KR-2: Her satırda SetLength yerine geometrik büyüme   │
│       KR-3: Birleştirilmemiş git merge çakışmasını temizle  │
└───────────────────────────┬─────────────────────────────────┘
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  P1 — Orta Vadeli: Okuma Maliyetini Düşür                   │
│       KR-4: Büyük taramalarda rastgele I/O → sıralı blok   │
│       KR-5: FlushIdxPending tam kopya+sıralama → delta merge│
│       KR-6: Her sorguda yeniden ayrıştırma → AST önbelleği  │
└───────────────────────────┬─────────────────────────────────┘
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  P2 — İleri Adımlar: Paralellik ve CBO Kalibrasyonu         │
│       KR-7: TCP sunucusunda seri yürütüm → okuma paralelliği│
└─────────────────────────────────────────────────────────────┘
```

---

## KR-1 — KRITIK: Tablo Taraması Tüm Veritabanını Tarıyor

### Sorun

`VDbTable.pas` içindeki `ScanRowsPart` şu adımları izler:

```pascal
// Mevcut kod (sorunlu):
FKv.ScanSnapshot(allKeys, allVals, SnapshotSeq);  // TÜM KV kayıtları yükle
for i := 0 to High(allKeys) do
begin
  if not DecodeRow(allVals[i], tid, pk, vals) then Continue;
  if tid <> t.TableId then Continue;   // diğer tabloları SONRADAN eler
  ...
end;
```

**Sonuç:** 1 milyon satırlı bir veritabanında 1 tabloyu aramak için **tüm diğer tabloların kayıtları da okunup decode edilir**. Diğer tablolara veri ekledikçe hedef tablonun tarama süresi büyür.

**SQLite ile fark:** SQLite B-tree'sinde her tablo ayrı kök sayfasına sahiptir. Başka tabloların sayfalarına hiç dokunulmaz.

### Çözüm — Tablo Başına Aktif Anahtar Dizini

**Aşama A (düşük riskli, hemen uygulanabilir):**

```pascal
// TVTableDb private alanlarına ekle:
FTableKeys: TDictionary<Word, TList<QWord>>;   // tableId -> aktif key listesi

// Open/Recover sırasında tek seferde kur:
procedure TVTableDb.BuildTableKeyIndex;
var
  allKeys: TQWordArray;
  allVals: TValArray;
  tid: Integer; pk: string; vals: TStrArray;
  i: Integer; lst: TList<QWord>;
begin
  FTableKeys.Clear;
  FKv.ScanAll(allKeys, allVals);
  for i := 0 to High(allKeys) do
  begin
    if not DecodeRow(allVals[i], tid, pk, vals) then Continue;
    if tid < 0 then Continue;
    if not FTableKeys.TryGetValue(Word(tid), lst) then
    begin
      lst := TList<QWord>.Create;
      FTableKeys.Add(Word(tid), lst);
    end;
    lst.Add(allKeys[i]);
  end;
end;

// ScanRowsPart: sadece o tablonun anahtarlarını dolaş:
if not FTableKeys.TryGetValue(t.TableId, tblKeys) then Exit;
for i := 0 to tblKeys.Count - 1 do
begin
  if not FKv.GetSnapshot(tblKeys[i], val, SnapshotSeq) then Continue;
  DecodeRow(val, ...);  // sadece bu tablo
end;
```

**Insert/Delete/Update'te dizini güncelle:** Eklemede `lst.Add(key)`, silmede `lst.Remove(key)`.

### Kabul Testi

```
Senaryo: musteri tablosu 10K satır, siparis tablosu 1M satır.
Beklenti: musteri taraması sipariş tablosu büyüdükçe ARTMAMALI.
Araç: bench1m.dpr benzeri senaryo.
```

**Beklenen Kazanım:** Karışık veritabanında 5–50x hızlanma.

---

## KR-2 — KRITIK: Her Satırda `SetLength(arr, n+1)` — O(N²) Bellek Kopyası

### Sorun

FPC'de dinamik dizilerde **amortize büyüme yoktur**. `SetLength(arr, Length(arr)+1)` her seferinde diziyi kopyalar.

Tarama döngüleri ve `FlushIdxPending` içinde:
```pascal
// Sorunlu örüntü — her satırda yeniden tahsis:
SetLength(Pks, n + 1);
SetLength(Rows, n + 1);
Inc(n);

// FlushIdxPending'de de:
SetLength(keep, Length(keep) + 1);
```

**Sonuç:** 100K satır taramada ~100K bellek tahsisi + kopyası → O(N²) zaman.

### Çözüm — Geometrik Kapasite Artışı

```pascal
// Yardımcı büyüme fonksiyonu:
procedure GrowAppend(var Arr: TStrArray; var Len, Cap: Integer; const S: string);
begin
  if Len >= Cap then
  begin
    if Cap = 0 then Cap := 64 else Cap := Cap * 2;
    SetLength(Arr, Cap);
  end;
  Arr[Len] := S;
  Inc(Len);
end;

// Tarama bitince gerçek uzunluğa küçült:
SetLength(Pks, actualLen);
SetLength(Rows, actualLen);
```

**Arama yöntemi:** Tüm VDbTable.pas ve VDbExecutor.pas içinde:
```
grep -n "SetLength.*Length.*+ 1"
```
Her eşleşmeyi geometrik büyümeye çevir.

**Beklenen Kazanım:** Büyük taramalarda 2–10x hızlanma.

---

## KR-3 — ACİL: Birleştirilmemiş Git Merge Çakışması

### Sorun

`VDbCore.pas` satır 48–105 ve 161–196 arasında **aktif `<<<<<<< HEAD` / `=======` / `>>>>>>>` işaretleri** var. Bu kod, FPC'nin sürümüne bağlı olarak mantıksal hata veya bozuk davranışa yol açabilir.

### Çözüm

```bash
cd D:\veritabani
git status
git diff HEAD b65c442 -- VDbCore.pas

# HEAD sürümünü al:
git checkout HEAD -- VDbCore.pas
# Sonra derle ve testleri çalıştır
```

> [!WARNING]
> Bu temizlenmeden yapılan diğer tüm optimizasyonlar hangi kodun çalıştığını belirsizleştirir.

---

## KR-4 — ORTA: Büyük Taramalarda Rastgele I/O

### Sorun

`VDbCore.pas` içinde `GetSnapshot`:
```pascal
FS.Position := loc.Offset;   // her kayıt için dosya konumu değiştirir (seek)
FS.Read(FReadBuf, ...)       // küçük rastgele okuma
```

`ScanSnapshot` tüm indeksi dolaşıp her kayıt için ayrı `Seek+Read` yapıyor.
Append-only dosyada kayıtlar sıralı yazıldığı halde sıralı okunmuyor.

`FReadCache` zaten var (`VDbCore.pas` satır 256–266), ancak:
- Eviction stratejisi belirsiz
- Büyük taramalarda cache dolar → tüm kayıtlar yeniden okunur

### Çözüm

```pascal
// ScanSnapshot için: offset'e göre sırala, sonra sıralı oku
procedure TVDb.ScanSnapshotOrdered(out Keys: TQWordArray; ...);
var
  locs: array of record Key: QWord; Offset: Int64; end;
begin
  // 1) Görünür konumları topla
  // 2) Offset'e göre küçükten büyüğe sırala (QuickSort)
  // 3) Sıralı dosya konumlarında oku → page cache'i etkili kullan
end;

// Cache boyutu: sabit sayı değil bellek tabanlı limit
FReadCacheMax := 32 * 1024 * 1024 div AvgRecordSize;  // 32MB
```

**Beklenen Kazanım:** Büyük taramalarda 1.5–5x I/O azalması.

---

## KR-5 — ORTA: `FlushIdxPending` Tam İndeksi Yeniden Sıralar

### Sorun

`FlushIdxPending` sonunda, 100 satır değişse bile 1M girdili indeks yeniden sıralanıyor:
```pascal
SortIdxEntries(merged, ctype);  // TÜM indeksi yeniden sıralar
FMemIdx[k] := merged;
```

### Çözüm — Delta Merge (2-way merge)

```pascal
// 1) Bekleyen delta'yı sırala (küçük)
SortIdxEntries(deltaEntries, ctype);   // yalnızca delta

// 2) Mevcut sıralı FMemIdx ile 2-way merge: O(n + delta)
MergeIdxEntries(FMemIdx[k], deltaEntries, merged, ctype);
FMemIdx[k] := merged;

procedure MergeIdxEntries(const A, B: TIdxEntries; out C: TIdxEntries; Ctype: Byte);
var ia, ib, ic: Integer;
begin
  SetLength(C, Length(A) + Length(B));
  ia := 0; ib := 0; ic := 0;
  while (ia < Length(A)) and (ib < Length(B)) do
  begin
    if VDbIdxCmp(A[ia].Key, B[ib].Key, Ctype) <= 0
      then begin C[ic] := A[ia]; Inc(ia); end
      else begin C[ic] := B[ib]; Inc(ib); end;
    Inc(ic);
  end;
  while ia < Length(A) do begin C[ic] := A[ia]; Inc(ia); Inc(ic); end;
  while ib < Length(B) do begin C[ic] := B[ib]; Inc(ib); Inc(ic); end;
  SetLength(C, ic);
end;
```

**Beklenen Kazanım:** Küçük güncelleme yüklerinde 2–20x hızlanma.

---

## KR-6 — ORTA: Her Sorguda Yeniden Ayrıştırma

### Sorun

`TVSql.ExecRaw` her çağrıda `TVDbParser.Create + Parse + TVSqlExecutor.Create` yapıyor.
REST API'de aynı sorgu saniyede 1000 kez çalışırsa → 1000 kez ayrıştırma.
SQLite **prepared statement** ile bunu bir kez yapar.

### Çözüm — AST Plan Önbelleği

```pascal
type
  TCachedPlan = record
    SqlHash: QWord;       // FNV-1a(sql_text)
    SchemaVer: Integer;   // şema değişince geçersiz
    Node: TSqlStmtNode;   // sahiplik önbellekte
  end;

  TVSql = class
  private
    FPlanCache: TDictionary<QWord, TCachedPlan>;
    FSchemaVer: Integer;  // DDL'de artır
```

**Geçersizleştirme kuralları:**
- `CREATE/DROP/ALTER TABLE` → `Inc(FSchemaVer)` → tüm önbellek geçersiz
- Parametre değerleri AST'de **değiştirilebilir** olmalı (önceki çağrı değerleri sızmamalı)
- Thread güvenliği: FLock altında erişim

**Beklenen Kazanım:** Kısa tekrarlanan sorgularda %30–60 CPU azalması.

---

## KR-7 — İLERİ: TCP Sunucusunda Seri Yürütüm

### Sorun

`VDbPool.pas` satır 16–20 (kendi yorumu):
> "Havuz paralelliği ÇARPMAZ, kaynak kullanımını SINIRLAR"

4 istemci eşzamanlı `SELECT` → tek `TCriticalSection` → sırayla çalışır → 1 çekirdek.

### Önkoşullar

1. KR-1 tamamlanmış (tablo anahtar dizini thread-safe)
2. Okuyucu başına ayrı file handle (paylaşımlı `TFileStream.Position` race condition)
3. `ScanSnapshot` yalnızca salt-okunur indeks verisi kullanır

### Çözüm

```pascal
FRwLock: TMultiReadExclusiveWriteSynchronizer;

// SELECT: BeginRead / EndRead → paralel
// INSERT/UPDATE/DELETE/DDL: BeginWrite / EndWrite → tekil
```

**Kabul Testi:**
```
1/2/4/8 eşzamanlı SELECT istemci → throughput ölçüm
Tek istemci performansı gerilememelidir
```

---

## Öncelik Sırası ve Takvim

| Sıra | Kök Neden | Risk | Beklenen Kazanım | Süre |
|------|-----------|------|-----------------|------|
| **1** | **KR-3** Merge çakışması | Sıfır | Güvenilir derleme | 1 saat |
| **2** | **KR-2** Dinamik dizi büyümesi | Düşük | 2–10x büyük tarama | 4 saat |
| **3** | **KR-1** Tablo anahtar dizini | Orta | 5–50x karışık DB | 1–2 gün |
| **4** | **KR-4** Sıralı I/O + cache | Düşük | 1.5–5x I/O azalması | 1 gün |
| **5** | **KR-5** Delta merge indeks | Düşük | 2–20x küçük güncelleme | 4 saat |
| **6** | **KR-6** AST önbelleği | Orta | %30–60 CPU azalması | 2 gün |
| **7** | **KR-7** RW Lock paralellik | Yüksek | N× okuma throughput | 3–5 gün |

---

## Benchmark Protokolü

Her adımı ölçmeden "hızlandı" demek doğru değildir:

```
bench1m.dpr → her KR için öncesi/sonrası çalıştır
Raporlanacaklar:
  - Süre (ms)
  - Throughput (satır/sn, sorgu/sn)
  - Tepe RAM kullanımı
  - Hangi iş yükleri geriledi (varsa)
```

---

## SQLite ile Karşılaştırma Tablosu

| Metrik | VDb (Şu An) | VDb (KR-1+2 Sonrası) | SQLite |
|--------|-------------|----------------------|--------|
| Full scan — 1 tablo, 10 tablo DB | O(toplam DB) | O(hedef tablo) | O(hedef) |
| 100K satır tarama — SetLength | O(N²) | O(N) | O(N) |
| Tekrarlanan SELECT parse | Her sorguda | KR-6 ile O(1) | Prepared O(1) |
| Eşzamanlı okuma | Seri | KR-7 ile paralel | WAL paralel |
| Tek PK lookup | O(1) hash | O(1) hash | O(log n) B-tree |

> Gerçek sayılar bench1m.dpr ile ölçülmelidir.

---

## Kesinlikle Dokunulmaması Gerekenler

- `VDB_FLAG_BATCHEND` atomik commit protokolü
- CRC32 bütünlük kontrolü
- `GuardSchemaLoss` şema ezilme koruması
- FK iki aşamalı denetim (RESTRICT önce, CASCADE sonra)
- `ROLLBACK DDL dahil` savepoint mekanizması
- `VDbCrypt.pas` AES-256-CTR şifreleme
- WAL + PITR arşivleme altyapısı
- Mevcut 982+ test seti

---

*Kaynak: `VDbCore.pas`, `VDbTable.pas`, `VDbPool.pas`, `bench1m.dpr` doğrudan incelenerek;  
`yol_haritasi_hiz.md` ve `vdb_analiz_raporu.md` temel alınarak hazırlanmıştır.*
