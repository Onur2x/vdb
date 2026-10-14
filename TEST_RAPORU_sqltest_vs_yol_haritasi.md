# sqltest.exe Test Raporu — Yol Haritası (yol_hariton.md) Karşılaştırması

## 1. Test Sonuçları (Final Form)

```
$ ./sqltest.exe
SONUC: gecen=1671 kalan=0
TUM SQL TESTLERI GECTI
```

- **Toplam test:** 1671
- **Başarısız:** 0
- Tüm testler başarıyla geçti.

## 2. Yol Haritası Madde Madde Kontrolü (yol_hariton.md → sqltest.exe / kod)

### 🟥 FAZ 0 — KRİTİK

| ID | Özellik | Harita İddiası | sqltest Karşılığı | Durum |
|----|---------|----------------|-------------------|-------|
| R-01 | **MVCC / Snapshot Isolation** | ✅ **BITTI** — Transaction-level snapshot (FBatchSnapshotSeq), Nested SELECT snapshot (FSnapshotDepth/FSnapshotSeq), Snapshot isolation for SELECT within transactions, BeginBatch/CommitBatch/AbortBatch | ❌ **YOK** — `FSnapshotDepth` dosyalarda hiç tanımlı değil; `GetSnapshot/ExistsSnapshot/IsVisible` VDbCore'de tanımlı ama **asla çağrılmıyor**; `BeginBatch`'ta FSnapshotSeq ayarı yok (sadece yorum satırı); `SnapshotSchema` DDL schema snapshot'ıdır, MVCC veri snapshot'ı değil | **KRİTİK UYARSIZLIK** |
| R-02 | SAVEPOINT / Nested Transaction | ✅ BITTI | ✅ T79_Savepoint — 7 test geçti (ROLLBACK TO sp, RELEASE, nesting) | UYUMLU ✅ |
| R-03 | UPSERT (ON CONFLICT) | ✅ BITTI | ✅ T10b_Upsert — 8 test (DO NOTHING, DO UPDATE, EXCLUDED, cnt=cnt+1, INSERT…SELECT, RETURNING) | UYUMLU ✅ |
| R-04 | RETURNING | ✅ BITTI | ✅ T11_Returning — 9 test (INSERT/UPDATE/DELETE RETURNING, *, kolon listesi, ifade, ON CONFLICT + RETURNING) | UYUMLU ✅ |

### 🟠 FAZ 1 — SQL Standartları

| ID | Özellik | Harita İddiası | sqltest Karşılığı | Durum |
|----|---------|----------------|-------------------|-------|
| R-05 | Trigger (F-36) | ✅ BITTI — 1645/1646 test, "1 edge case hariç", cascade logic | ✅ T08n_Trigger — tüm testler geçti (BEFORE/AFTER/INSTEAD OF, ROW/STATEMENT, WHEN, OLD/NEW, nested trigger, DROP, IF EXISTS) | **UYUMLU ama eski not var** ⚠️ |
| R-06 | View (Real) + VIEW DML | ✅ BITTI — VIEW DML çalışıyor | ✅ T08l_ViewDML — INSERT/UPDATE/DELETE on view, alias view, aggregate/DISTINCT/GROUP BY view reddediyor | UYUMLU ✅ |
| R-07 | Materialized View | ✅ BITTI | ✅ T08k_MatView — CREATE/REFRESH, IF EXISTS, DROP | UYUMLU ✅ |
| R-08 | Stored Procedure/Function | ✅ BITTI | ✅ T08m_StoredProc — CREATE/DROP, parametre, CALL, SELECT func(), RETURN | UYUMLU ✅ |
| R-09 | LATERAL JOIN | ✅ BITTI | ✅ T08j_Lateral — 9 test (alt sorgu, LEFT LATERAL koruma, tablo, ON, HATA durumları) | UYUMLU ✅ |
| R-10 | CYCLE Detection (Recursive CTE) | ✅ BITTI | ✅ T08e_CTE — RECURSIVE + `CYCLE n SET is_cycle USING path`, is_cycle okunabilir, hata durumu | UYUMLU ✅ |
| R-11 | DEFERRABLE Constraints | ✅ BITTI | ✅ T12_Transaction — SET CONSTRAINTS ALL DEFERRED/IMMEDIATE, COMMIT reddi, NOT DEFERRABLE kontrol | UYUMLU ✅ |

### 🟡 FAZ 2 & 🟢 FAZ 3 (R-12 … R-24)

- Hiçbiri haritada **BITTI** olarak işaretli değil (🔴/🟠/🟡/🟢 başlangıç öncelikleri var).
- sqltest'te de bu özellikler için test yok (Connection Pool multi-process, Partitioning, Parallel Query, Cost-Based Optimizer, WAL Archiving, Streaming Replication, RBAC, RLS, ICU Collation, Extension, Online DDL, Cross-Platform DLL, Monitoring).
- **Harita ile test durumu UYUMLU** — başlanmamış özellikler açıkça işaretli.

## 3. Tespit Edilen Eksiklikler / Uyarsızlıklar

### 3.1 R-01 MVCC — Harita yanlış / aşırı iddialı (EN ÖNEMLİ)

Haritada "✅ BITTI" olan R-01'in hiçbir alt bileşeni çalışmıyor:

- `FSnapshotDepth` identifier'ı hiç tanımlı değil (herhangi bir .pas dosyasında yok)
- `GetSnapshot / ExistsSnapshot / IsVisible` fonksiyonları VDbCore.pas'ta tanımlı ama **kullanılmıyor** (kullanım: 0)
- `TVDb.BeginBatch` yorumu *"TVTableDb.BeginBatch FSnapshotSeq := FKv.FSeq yapar"* diyor ama kodda böyle bir satır **yok**
- `SnapshotSchema` — DDL değişikliklerinden önce şema snapshot'ı (veritabanı/transaction snapshot'ı değil)
- sqltest'te **hiçbir MVCC/snapshot izolasyon testi yok** (örn. "transaksiyon içi okuyucu yazıcıyı bekliyor mu?" gibi)

**Sonuç:** R-01 şu an sadece iskelet/kod dokusu (planned stub). Harita **devam ediyor / başlamadı** olarak güncellenmeli. Bu, harita-garantisi ile gerçeklik arasındaki en ciddi fark.

### 3.2 R-05 Trigger — Eski sayısal not (hata değil, sadece güncelleme)

Haritada *"1645/1646 test → TÜM TESTLER GECTI (1 edge case hariç)"* yazıyor.
Gerçeklik: sqltest'te 1671/0. "1 edge case hariç" ifadesi eskimiş — artık hata yok. Bu satır temizlenmeli.

### 3.3 R-05 Trigger — ON DELETE CASCADE tetikleyici testi yok

- `T08n_Trigger` BEFORE/AFTER/INSTEAD OF, ROW/STATEMENT, WHEN, nested, cascade **trigger** testlerini kapsamıyor.
- SQL.md/DENETIM'de "cascade logic" geçse de, sqltest'te `ON DELETE CASCADE` tetikleyicisi testi bulunmuyor
- (FK ON DELETE CASCADE testi var: T42_F1_BatchInsertAtomik, T54_F2_UnionDistinct, F2-12 — sadece FK düzeyinde)

**Öneri:** Opsiyonel — trigger bazlı CASCADE desteğini test et.

### 3.4 R-08 Stored Procedure — Haritada "F-35: parametre skope + skaler alt sorgu (WHERE'de tablo kolonu/parametre çakışması çözüldü — 32/32)" 

- Haritada "32/32" ifadesi eski bir test sayısına işaret ediyor; T08m_StoredProc test sayısı daha az ama özellikler çalışıyor. Not güncelleme gerekebilir (kritik değil).

## 4. Özet Karar

| Kategori | Durum |
|----------|-------|
|sqltest.exe çalışıyor mu? | ✅ Evet — 1671/0, hata yok |
| Haritada BITTI olanlar test ediliyor mu? | ✅ R-02…R-11 hepsi sqltest'te var ve geçiyor |
| Haritada BITTI ama **kodsuz** olan? | ❌ **R-01 MVCC** — kod iskeleti var ama aktif değil, test yok |
| Haritada BITTI ama **eski not** içeren? | ⚠️ R-05 (1645/1646 + "1 edge case hariç") |
| Test edilen ama haritada olmayan? | Hayır — testler haritadaki FAZ 0/FAZ 1 maddelerine karşılık geliyor |
| FAZ 2/3 | Harita ile test uyumlu (başlanmamış) |

## 5. Önerilen Sonraki Adımlar

1. **yol_hariton.md → R-01 MVCC "BITTI" → "DEVAM EDİYOR / BAŞLANMADI"** olarak güncelle. MVCC için planlanmış iş:
   - `FSnapshotDepth` yerine nested SELECT için snapshot stack mekanizması
   - `GetSnapshot` çağrılarını VDbTable/VDbSql tarama yollarına entegre et
   - En az 2-3 MVCC test ekle (transaksiyon içi snapshot, nested select snapshot, commit sonrası görünürlük)
2. **R-05 Trigger notunu temizle** ("1645/1646", "1 edge case hariç" satırlarını sil).
3. Opsiyonel: R-05'e `ON DELETE CASCADE` trigger testi ekle.
4. Proje şu an production-ready bir embedded DB olarak kullanılabilir (tek kullanıcı, dosya başına): MVCC, multi-process, partitioning, RLS, extension yok → README'deki "Uygun mu?" tablosu **hala doğru**.
