# MTAKIP Projesi — Test Sonuçları Raporu

**Rapor tarihi:** sqltest.exe yeniden derlendi + testler tekrar yapıldı

## B. YENİ DERLEME — sqltest.lpr → sqltest.exe

```bash
$ /d/Onur_Yedek/mailler/lazarus/lazbuild sqltest.lpi
```

- 42903 satır derlendi, 9.9 sn
- **Hata: 0** | 170 uyarı (warning/hint — normal)
- `sqltest.exe` 11.10.2026 23:15'te yeniden üretildi (8.9 MB)

### Yeniden derlenen exe — test tekrarı (3 kez, tutarlılık)
```
ÇALIŞMA 1: SONUC: gecen=1671  kalan=0 | TUM SQL TESTLERI GECTI
ÇALIŞMA 2: SONUC: gecen=1671  kalan=0 | TUM SQL TESTLERI GECTI
ÇALIŞMA 3: SONUC: gecen=1671  kalan=0 | TUM SQL TESTLERI GECTI
```
- **Tutarlılık:** Çıktılar özdeş, tek farklar: temp klasör adı (zaman damgası içeriyor) + zaman ölçümleri (örn. ağır sorgu 31ms→15ms) — test mantığında fark yok.
- Önceki build ile **test sonuçları birebir aynı**.

---

## A. SQL MOTORU TESTLERİ — `sqltest.exe` (sqltest.lpr)

### Çalıştırma
```
$ ./sqltest.exe
SONUC: gecen=1671  kalan=0
TUM SQL TESTLERI GECTI
```
**Tutarlılık testi:** 3 kez arka arkaya çalıştırıldı, her seferinde **1671/0** aynı sonuç.

### Kapsam (test grupları)
- Veritabanı komutları, veritabanı yönetimi, veri tipleri, CREATE TABLE kısıtları
- INSERT / SELECT / WHERE, JOIN (LEFT/RIGHT/FULL/CROSS/NATURAL/USING), LATERAL JOIN
- Materyalize View, VIEW DML (güncellenebilir view, alias view, reddedilen view'lar)
- Stored Procedure / Function, TRIGGER (BEFORE/AFTER/INSTEAD OF, ROW/STATEMENT, WHEN, OLD/NEW, nested)
- RECURSIVE CTE + CYCLE, WINDOW functions, COLLATION, aggregate (GROUP BY/HAVING/GROUPING/CUBE/ROLLUP)
- CASE/WHEN, COALESCE, ANY/SOME/ALL, LIKE/ILIKE, XML, SPATIAL, RANGE, qual, filter, explain
- Index: covering, expression, partial, unique, index flush
- DDL atomikliği, alter table (rename/drop/switch/lock/cascade), batch insert atomikliği
- Transaction: COMMIT/ROLLBACK, DDL içinde transaction, DEFERRABLE constraints
- Parameterized queries, BLOB, durability, migration (legacy), parser derinlik sınırı
- İki ifade bloğu, split statements, semantik hatalar, dosya bozuklukları, recovery, verify BATCHEND
- JSONB, UPDATE, DELETE, UPSERT (ON CONFLICT), RETURNING, AS OF, checkpoint, WAL

---

## B. UYGULAMA BÜTÜNLÜK TESTİ — `mtverify.exe`

### Çalıştırma
```bash
$ ./mtverify.exe
```

**Anlamı:** Gömülü referans JSON ile `.odb` veritabanı satır satır + fotoğraf bayt-bayt karşılaştırıldı. **KAYIPSIZ İÇERİ AKTARIM** doğrulandı. Şifreler korundu.

---

## C. WEB SUNUCUSU — `mtakipwebsrv.exe`

### Çalıştırma
```
$ ./mtakipwebsrv.exe
Makinist Takip Web Server
  veri : .../mtakip/data
  web  : .../mtakip/web_prototype
  hat  : M8
Veritabani   : .../mtakip/data/mtakip.odb
Yedek        : backup\saat (24 adet) + backup\gun (14 adet)
Dinleniyor: http://127.0.0.1:8900/  (pano: /pano.html?hat=M8)
...
```

### HTTP testleri (curl)
| İstek | Sonuç |
|-------|-------|
| `http://127.0.0.1:8900/` → `/pano.html` | HTTP 200, 41474 bayt |
| `http://127.0.0.1:8900/pano.html` | HTTP 200 |
| `http://127.0.0.1:8900/hatlar.json` | HTTP 200 |

**Sonuç:** Web sunucusu dinliyor, veritabanı açılıyor, saatlik/günlük yedekleme zamanlayıcısı çalışıyor, tüm sayfa/endpoint testleri başarılı.

---

## D. İÇERİ AKTARMA ARACI — `mtimport.exe`

```
$ ./mtimport.exe
HATA: data klasorunde veri_*.json bulunamadi
```

**Beklenen durum.** Bu araç JSON → .odb bir kez aktarma içindir; aktarma bitince JSON dosyaları silinir. Şu an çalışması için gerekli `veri_*.json` girdileri yok → hata doğru davranış. Bir test değil, yapılandırma bağımlılığı.

---

## ÖZET TABLOSU

| Test aracı | Durum | Detay |
|------------|-------|-------|
| `sqltest.exe` | ✅ PASS | 1671/0, 3 tekrar tutarlı |
| `mtverify.exe` | ✅ PASS | JSON ↔ ODB kayıpsız, şifreler tamam (kilitli arka plan sunucusu temizlendikten sonra) |
| `mtakipwebsrv.exe` | ✅ PASS | HTTP 200, yedekleme çalışıyor, pano/hatlar.json yükleniyor |
| `mtimport.exe` | ⚠️ N/A | Tek kullanımlık aktarıcı, `veri_*.json` girdi dosyaları yok (beklenen durum) |

---

## YOL HARİTASI KARŞILAŞTIRMASI — `yol_hariton.md` vs `sqltest`

### ✅ UYUMLU (haritada BITTI, testlerde de var ve geçiyor)
| Madde | sqltest grubu |
|-------|---------------|
| R-02 SAVEPOINT | T79_Savepoint |
| R-03 UPSERT | T10b_Upsert |
| R-04 RETURNING | T11_Returning |
| R-05 Trigger | T08n_Trigger |
| R-06 View DML | T08l_ViewDML |
| R-07 Materialized View | T08k_MatView |
| R-08 Stored Proc/Function | T08m_StoredProc |
| R-09 LATERAL JOIN | T08j_Lateral |
| R-10 RECURSIVE + CYCLE | T08e_CTE |
| R-11 DEFERRABLE | T12_Transaction |

### ❌ KRİTİK UYARSIZLIK — R-01 MVCC/Snapshot Isolation
- Harita: "✅ BITTI" (Transaction-level snapshot, Nested SELECT snapshot via FSnapshotDepth, BeginBatch/CommitBatch/AbortBatch)
- Gerçeklik: `FSnapshotDepth` hiç yok; snapshot API (GetSnapshot/ExistsSnapshot/IsVisible) tanımlı ama **kullanılmıyor**; BeginBatch'ta FSnapshotSeq ayarı yok; sqltest'te **MVCC testi yok**.
- **R-01 haritada "BITTI" gösterilmemeli; "DEVAM EDİYOR / BAŞLANMADI" olmalı.**

### ⚠️ ESXİ NOTLAR (fonksiyonel değil, sadece güncelleme)
- R-05 Trigger: "1645/1646 test, 1 edge case hariç" → günümüzde 1671/0 (not temizlenmeli)
- R-05: "cascade logic" ifadesi → trigger bazlı ON DELETE CASCADE testi yok (sadece FK CASCADE var)

---

## SONUÇ

Proje **çalışma durumda**: tüm test araçları başarılı, motor 1671 SQL testini geçiyor, veritabanı bütünlüğü doğrulanıyor, web sunucusu çalışıyor. Yapılacaklar:

1. `yol_hariton.md` → **R-01 MVCC "BITTI" → "DEVAM EDİYOR/Başlanmadı"** (kodda iskelet var, aktif değil)
2. `yol_hariton.md` → **R-05 Trigger eski notları temizle** ("1645/1646", "1 edge case hariç")
3. Opsiyonel: R-05'e trigger bazlı ON DELETE CASCADE testi ekle
4. Opsiyonel: R-08 Stored Proc notunu ("32/32") güncelle

Proje şu an production-ready bir embedded DB: MVCC, multi-process, partitioning, RLS, extension yok → README'deki uygunluk tablosu hâlâ doğru.