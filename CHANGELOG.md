# CHANGELOG — VDB (VeriTabanı)

Bu dosya sürümler arasında **ne yapıldığını** izler. Her sürümde: değişen
dosyalar, ölçülmüş etki ve (varsa) **bilinçli olarak yapılmayan** şeyler.

Sürümleme notu: motor dokümanlarında uzun süredir `2.0` (R-12 Full + 24 yol
haritası maddesi) ibaresi var; `v0.00x` serisi bu **performans/ölçüm**
akışını izler.

---

## v0.011 — 2026-10-16 — Hız turu: P-21 COMMIT toplu yazım tamponu

### Ne eklendi / değişti

- **P-21 — COMMIT toplu yazım (VDbCore):** `CommitBatch`, bekleyen kayıtları
  **tek tek** `AppendRec` ile dosyaya yazıyordu (kayıt başına `FS.Seek` +
  `WriteBuffer`). Artık kayıt baytları (başlık+değer) bellekte **1 MB'lık
  tampona** biriktirilir ve eşik aşılınca `FlushWriteBuf` ile **tek
  `WriteBuffer`** olarak dosyaya boşaltılır. Diskteki bayt akışı **birebir
  aynıdır**: aynı baytlar, aynı sıra, aynı offset (`FWrBufBase` + tampondaki
  konum). Yalnız syscall sayısı düşer (kayıt başına ≈2 → ≈blok başına 2).
  `AppendRec`'in başlık/CRC/indeks/ölü-bayt mantığı **hiç değişmedi**;
  yalnızca son dosya yazımı yönlendirilir.
- **Güvenlik (pazarlık dışı):** `FlushWriteBuf`, dosya sonu `FWrBufBase` ile
  **uyuşmazsa yazmaz**, görünür `ecIOError` verir — sessiz veri bozulması
  imkânsız. Tampon **yalnızca `FLock` altında ve `CommitBatch` süresince**
  aktiftir; başka her yolda (`Put`/`Delete`/`Recover`/replay/Compact)
  `FWrBufActive = False` → **eski yol birebir**. Hata yolunda yazılmamış
  tampon baytları diske **hiç gitmez**; mevcut `FS.Size := savedSize` +
  `Recover` geri sarma yolu aynen çalışır (bkz. v0.006–v0.009).
- **Çoklu platform:** yalnız bellek içi + mevcut `TFileStream` yazımı
  kullanılır; platforma özel kod **yok**.

### Ölçülmüş sonuç (aynı-koşu A/B, 200K)

| Ölçüm | Önce | Sonra | Fark |
|---|---|---|---|
| `kv.Put` + commit (bench31 K) | 7,04 µs | **2,00 µs** | −%72 |
| bench27 `INSERT` hızlı şerit | 32,80 µs | **23,67 µs** | −%28 |
| bench27 `UPDATE` | 48,75 µs | **39,72 µs** | −%19 |
| bench27 `DELETE` | 34,12 µs | **27,72 µs** | −%19 |
| bench27 `sink` / `dokunma` | 569999 / 99995 | **569999 / 99995** | **birebir** ✓ |

### Ölçülmüş sonuç — adil kıyas run8 → run9 (1M satır, tek süreç)

| Aşama | run8 VDB | run9 VDB | SQLite (run9) | run9 oranı |
|---|---|---|---|---|
| INSERT 1M (tx) | 29,0 sn | **24,1 sn** | 3,12 sn | 7,73x |
| UPDATE 100k | 4,68 sn | **4,25 sn** | 269,7 ms | 15,75x |
| DELETE 100k | 3,36 sn | **2,92 sn** | 195,9 ms | 14,89x |
| SELECT PK 50.000x | 1,41 sn | 1,42 sn | 3,04 sn | **0,47x** (VDB 2,1x önde) |
| RANGE 2.000×100 | 3,11 sn | 3,12 sn | 211,1 ms | 14,77x |
| COUNT x10 | 698 ms | 713 ms | 36,5 ms | 19,53x |
| SUM x5 | 733 ms | 722 ms | 82,2 ms | 8,79x |

run9'da SQLite'ın kendi sayıları run8'e göre **sabit** (INSERT 3,14→3,12;
PK 3,06→3,04; RANGE 215,7→211,1) → makine sakin, kazanç **gerçek kod
etkisidir**. Kampanya başına (run6) göre: INSERT 34,0→**24,1** (−%29),
UPDATE 6,97→**4,25** (−%39), DELETE 4,85→**2,92** (−%40).

### Doğrulama (sıfırdan)

- `fpc -B` temiz (sqltest 56.488; crashtest 45.469 satır).
- `sqltest` **2251/2251**, kalan=0 (`sqltest_p21.log`).
- crashtest 8'li çarpma zinciri **8/8** (`c8_p21.log`) — çok-bloklu (33 MB)
  commit dahil veri kaybı/bozulma yok, `SyncWriteInterval=0` değişmedi.
- run9 doğrulaması: COUNT 1M ✓, DELETE sonrası 900k ✓,
  SUM=5000000000 ✓.

---

## v0.011 — 2026-10-16 — Speed round: P-21 batched COMMIT write buffer (ENGLISH)

### Added / changed

- **P-21 — batched COMMIT write (VDbCore):** `CommitBatch` wrote the pending
  records **one by one** via `AppendRec` (`FS.Seek` + `WriteBuffer` per
  record). Record bytes (header+value) now accumulate in a **1 MB in-memory
  buffer** and are flushed with a **single `WriteBuffer`** when the threshold
  is crossed (`FlushWriteBuf`). The on-disk byte stream is **bit-identical**:
  same bytes, same order, same offset (`FWrBufBase` + position in the
  buffer). Only the syscall count drops (≈2 per record → ≈2 per block).
  `AppendRec`'s header/CRC/index/dead-byte logic is **unchanged**; only the
  final file write is redirected.
- **Safety (non-negotiable):** if the file end does not match `FWrBufBase`,
  `FlushWriteBuf` **writes nothing** and raises a visible `ecIOError` —
  silent corruption is impossible. The buffer is active **only under `FLock`
  and only during `CommitBatch`**; on every other path (`Put`/`Delete`/
  `Recover`/replay/Compact) `FWrBufActive = False` → the **old path runs
  verbatim**. On the error path the unwritten buffer bytes **never touch
  disk**; the existing `FS.Size := savedSize` + `Recover` rollback path runs
  unchanged.
- **Cross-platform:** only in-memory work plus the existing `TFileStream`
  write; **no** platform-specific code.

### Measured — fair comparison run8 → run9 (1M rows, single process)

See the Turkish table above. SQLite's own numbers are **flat** from run8 to
run9 (INSERT 3.14→3.12, PK 3.06→3.04, RANGE 215.7→211.1), so the machine is
quiet and the gain is a **real code effect**. Versus the campaign baseline
(run6): INSERT 34.0→**24.1** (−29%), UPDATE 6.97→**4.25** (−39%),
DELETE 4.85→**2.92** (−40%).

### Verification (from scratch)

- Clean `fpc -B` builds; `sqltest` **2251/2251** (`sqltest_p21.log`);
  crashtest **8/8** (`c8_p21.log`) — including the multi-block (33 MB)
  commit; `SyncWriteInterval=0` unchanged. run9: COUNT 1M ✓, 900k after
  DELETE ✓, SUM=5000000000 ✓.

---

## v0.010 — 2026-10-16 — Hız turu: P-19 konumsal okuma + P-19w birleşik ekleme + P-20 ayırıcı hızlı yolu

### Ne eklendi / değişti

- **P-19 — konumsal tek okuma (`VDbPosRead`, VDbCore):** `GetSnapshot`
  (nokta PK/KV okuma yolu) eskiden `FS.Size` + `FS.Position` + `FS.Read` +
  `FS.Read` ile **4 syscall** yapıyordu (dosya sonu, konum, başlık, değer).
  Artık offsetli **tek** okuma: Windows'ta `ReadFile` + `OVERLAPPED`
  (`kernel32.dll`'den `external` bağlanır — `Windows` birimi `uses`'a
  EKLENMEZ; `TCriticalSection` gölgelenirdi), diğer platformlarda
  `System.FileSeek` + `FileRead` (FPC'nin kendi `THandleStream` ilkelleri,
  4→2). Başarısızlık veya aralık sapmasında **eski yol birebir** çalışır;
  hata sınıflandırma sırası ve mesajları korunur (dosya dışı → başlık
  eksik → index/data uyuşmazlığı → DEL → değer eksik). `loc.Size >
  VDB_POSREAD_MAX (16 MB)` → eski yol.
- **P-19w — birleşik ekleme yazımı (`AppendRec`, VDbCore):** `FS.Seek(0,
  soEnd)` + başlık + değer = **3 syscall** idi; artık başlık+değer **tek**
  `WriteBuffer` (2 syscall). `FS.Seek(0, soEnd)` **korunur**: dosya sonunun
  tek yetkili kaynağı budur; offset'i bellekte tutmak (in-place
  `FS.Position`, rollback `FS.Size:=`, `Compact`, truncate yollarında) bir
  kez invalide edilmediğinde **sessiz veri bozulması** riski taşırdı —
  güvenlik > mikro kazanç. Yazılan baytlar/sıra/offset birebir aynıdır.
  `ValLen > VDB_COMBINE_MAX (64 KB)` → geçici kopya ayırmamak için eski yol.
- **P-20 — `SplitStatements` hızlı yolu (VDbSql):** ayırıcı her kelimeyi
  karakter karakter `w := w + S[i]` ile kuruyordu (100 karakterlik bir
  INSERT'te ~15 kelime, her biri yeniden ayrılıyor). **Hiç `;` yoksa**
  sonuç kanıtlanabilir biçimde `[Trim(S)]` (ya da boş) olduğundan `Pos(';',
  S) = 0` hızlı yolu eklendi; tirnak/yorum içindeki `;` durumları genel
  yola düşer. Çok-ifadeli betikler aynen genel yolu kullanır.

### Ölçülmüş sonuç (aynı-koşu A/B, 200K)

| Ölçüm | Önce | Sonra | Fark |
|---|---|---|---|
| `kv.Get` (aynı anahtar, bench28) | 6,71 µs | **1,83 µs** | −%73 |
| `kv.Get` (rastgele) | 7,57 µs | **2,57 µs** | −%66 |
| `tb.ReadRow` (bench27) | 10,07 µs | **5,73 µs** | −%43 |
| SQL BETWEEN (satır başı) | 19,62 µs | **14,52 µs** | −%26 |
| Ham ekleme yolu (bench32) | 6,04 µs | **3,98 µs** | −%34 |
| `SplitStatements(INSERT)` (bench35) | 2,87 µs | **1,02 µs** | −%64 |

### Ölçülmüş sonuç — adil kıyas run6 → run8 (1M satır, C:\temp, tek süreç)

| Aşama | run6 VDB | run8 VDB | SQLite (run8) | run8 oranı |
|---|---|---|---|---|
| INSERT 1M (tx) | 34,0 sn | **29,0 sn** | 3,14 sn | 9,24x |
| SELECT PK 50.000x | 1,95 sn | **1,41 sn** | 3,06 sn | **0,46x** (VDB 2,2x önde) |
| RANGE 2.000×100 | 4,19 sn | **3,11 sn** | 215,7 ms | 14,43x |
| UPDATE 100k | 6,97 sn | **4,68 sn** | 267,1 ms | 17,52x |
| DELETE 100k | 4,85 sn | **3,36 sn** | 193,7 ms | 17,36x |
| COUNT x10 | 721 ms | 698 ms | 35,4 ms | 19,69x |
| SUM x5 | 802 ms | 733 ms | 81,9 ms | 8,95x |

Makine durumu run8'de SQLite'ı da hızlandırdığından (INSERT 3,64→3,14 sn),
makineden bağımsız **oran** belirleyicidir: PK 0,59→**0,46x**, RANGE
19,3→**14,4x**, DELETE 23,6→**17,4x**. Doğrulama: COUNT 1M ✓, DELETE
sonrası 900k ✓, SUM=5000000000 ✓ (`vsbench_run8.log`).

### Doğrulama (sıfırdan)

- `fpc -B` temiz (sqltest 56.405; crashtest 45.386 satır).
- `sqltest` **2251/2251**, kalan=0 (`sqltest_p20.log`).
- crashtest 8'li çarpma zinciri **8/8** (`c8_p20.log`) —
  `SyncWriteInterval=0` dayanıklılık sözleşmesi değişmedi.

---

## v0.010 — 2026-10-16 — Speed round: P-19 positional read + P-19w combined append + P-20 splitter fast path (ENGLISH)

### Added / changed

- **P-19 — single positional read (`VDbPosRead`, VDbCore):** `GetSnapshot`
  (point PK/KV read path) used `FS.Size` + `FS.Position` + `FS.Read` +
  `FS.Read` — **4 syscalls** (file size, position, header, value). It is now
  a single offset read: `ReadFile` + `OVERLAPPED` on Windows (`external`
  from `kernel32.dll` — the `Windows` unit is NOT added to `uses`, it would
  shadow `TCriticalSection`), `System.FileSeek` + `FileRead` elsewhere
  (FPC's own `THandleStream` primitives, 4→2). On any failure or range
  mismatch the **old path runs verbatim**; error classification order and
  messages are preserved. `loc.Size > VDB_POSREAD_MAX (16 MB)` → old path.
- **P-19w — combined append write (`AppendRec`, VDbCore):** `FS.Seek(0,
  soEnd)` + header + value was **3 syscalls**; now header+value go out in a
  single `WriteBuffer` (2 syscalls). `FS.Seek(0, soEnd)` is **kept**: it is
  the single authority for the end of file; tracking the offset in memory
  (in-place `FS.Position`, rollback `FS.Size:=`, `Compact`, truncate paths)
  would risk silent corruption if invalidated even once — safety over
  micro-gain. Bytes, order and offset are bit-identical. `ValLen >
  VDB_COMBINE_MAX (64 KB)` → old path, to avoid a temp copy.
- **P-20 — `SplitStatements` fast path (VDbSql):** the splitter built every
  word char-by-char (`w := w + S[i]`). When there is **no `;` at all** the
  result is provably `[Trim(S)]` (or empty), so a `Pos(';', S) = 0` fast
  path was added; `;` inside quotes/comments still falls to the general
  path. Multi-statement scripts are untouched.

### Measured (same-run A/B, 200K)

| Measurement | Before | After | Delta |
|---|---|---|---|
| `kv.Get` (same key, bench28) | 6.71 µs | **1.83 µs** | −73% |
| `kv.Get` (random) | 7.57 µs | **2.57 µs** | −66% |
| `tb.ReadRow` (bench27) | 10.07 µs | **5.73 µs** | −43% |
| SQL BETWEEN (per row) | 19.62 µs | **14.52 µs** | −26% |
| Raw append path (bench32) | 6.04 µs | **3.98 µs** | −34% |
| `SplitStatements(INSERT)` (bench35) | 2.87 µs | **1.02 µs** | −64% |

### Measured — fair comparison run6 → run8 (1M rows, C:\temp, single process)

See the Turkish table above; the machine-independent **ratio** is the
decider: PK 0.59→**0.46x**, RANGE 19.3→**14.4x**, DELETE 23.6→**17.4x**.
Verification: COUNT 1M ✓, 900k after DELETE ✓, SUM=5000000000 ✓
(`vsbench_run8.log`).

### Verification (from scratch)

- Clean `fpc -B` builds; `sqltest` **2251/2251** (`sqltest_p20.log`);
  crashtest **8/8** (`c8_p20.log`) — the `SyncWriteInterval=0` durability
  contract is unchanged.

---

## v0.009 — 2026-10-16 — Hız turu: P-15b PK tembel indeksinin sıfır-kopya kurucusu

### Ne eklendi / değişti

- **P-15b — `BuildPkIdx` peek-rebuild (VDbTable):** BETWEEN/ORDER BY için
  tembel (lazy) kurulan PK sıralı indeksi eskiden `ScanRows` ile **tüm
  tabloyu 5 kolonluk string matrisine decode edip matrisi çöpe atıyor**,
  yalnız PK sütununu alıyordu (1M'de ~1–3 sn + yüzlerce MB geçici). Artık
  `ScanRawIterAll` (P-18a) geri çağrısında `VDbPeekRawRowP` ile PK'lar
  kopyalanmadan toplanıyor. Görünür satır kümesi `ScanAll` ile **birebir**:
  aynı fazlar, aynı snapshot seçim kuralı, aynı pending görünürlüğü, aynı
  bucket sırası; girişler yine aynı `SortIdxEntries` ile sıralanır
  (PK'lar benzersiz olduğundan çıktı dizisi birebir aynıdır).
- **Anomali = tam teslim:** peek False (eski sema — `ALTER` sonrası eski
  satırlar — veya kesik kayıt) ya da hash çakışması görülürse hızlı kurucu
  BAIL eder ve **eski yol AYNEN** yeniden çalışır: F2-16
  `ecCorrupt` / `ecHashCollision` mesajları, sema-evrimli tabloların
  davranışı birebir korunur. Hızlı kurucu hiçbir motor hatası üretmez.
- Aynı kurucu `TryGetMemIndex` üzerinden ORDER-BY-indeks ve JOIN yollarının
  ilk kurulumunu da besler; üçü de yararlanır.

### Ölçülmüş sonuç — adil kıyas run5 → run6 (1M satır, C:\temp, sessiz makine)

| Aşama | run5 VDB | run6 VDB | SQLite | VDB/SQLite (run6) |
|---|---|---|---|---|
| RANGE 2.000×100 | 6,63 sn | **4,19 sn** | 217 ms | 28,3x → **19,3x** |
| INSERT 1M (tx) | 34,2 sn | 34,0 sn | 3,64 sn | 9,4x (değişmedi — yol dışı) |
| COUNT x10 | 695 ms | 721 ms | 41 ms | 17,6x (gürültü bandı) |
| UPDATE 100k | 6,97 sn | 6,97 sn | 388 ms | 18,0x (SQLite yanındaki dalgalanma) |

RANGE dışındaki aşamalar bilinçli olarak değişmedi; run5→run6 farkları
okuma/gürültü bandındadır (`vsbench_run5.log`, `vsbench_run6.log`).
Kampanya başına (run4) göre: INSERT 16,1x→9,4x; COUNT 26,8x→17,6x;
RANGE ~35x→19,3x; PK nokta araması 0,59x (VDB 1,7x ÖNDE).

### Doğrulama (sıfırdan)

- `fpc -B` temiz (sqltest 56.248; crashtest 45.229 satır).
- `sqltest` **2251/2251**, kalan=0 (`sqltest_p15b.log`).
- crashtest 8'li çarpma zinciri **8/8** (`c8_p15b.log`) —
  `SyncWriteInterval=0` dayanıklılık sözleşmesi değişmedi.

---

## v0.009 — 2026-10-16 — Speed round: P-15b zero-copy builder for the lazy PK index (ENGLISH)

### Added / changed

- **P-15b — `BuildPkIdx` peek-rebuild (VDbTable):** the lazy sorted PK
  index (for BETWEEN/ORDER BY) used to be built through `ScanRows`, which
  decoded the WHOLE table into a 5-column string matrix and threw the
  matrix away, keeping only the PK column (~1–3 s plus hundreds of MB of
  garbage at 1M rows). The builder now collects PK strings copy-free via
  `VDbPeekRawRowP` inside a `ScanRawIterAll` (P-18a) callback. The visible
  row set is BIT-IDENTICAL to `ScanAll`: same phases, same snapshot
  selection rule, same pending visibility, same bucket order; entries are
  sorted by the same `SortIdxEntries` (PKs are unique, so the resulting
  array is identical).
- **Anomaly = full handback:** on peek-False (old schema — pre-`ALTER`
  rows — or truncated record) or a hash collision the fast builder BAILs
  and the OLD path re-runs VERBATIM: F2-16 `ecCorrupt` / `ecHashCollision`
  messages and schema-evolution behavior are preserved exactly. The fast
  builder itself never raises engine errors.
- The same builder feeds `TryGetMemIndex`, so the ORDER-BY-index and JOIN
  first-build paths benefit too.

### Measured — fair comparison run5 → run6 (1M rows, C:\temp, quiet machine)

| Phase | run5 VDB | run6 VDB | SQLite | VDB/SQLite (run6) |
|---|---|---|---|---|
| RANGE 2,000×100 | 6.63 s | **4.19 s** | 217 ms | 28.3x → **19.3x** |
| INSERT 1M (tx) | 34.2 s | 34.0 s | 3.64 s | 9.4x (unchanged — off-lane) |
| COUNT x10 | 695 ms | 721 ms | 41 ms | 17.6x (noise band) |
| UPDATE 100k | 6.97 s | 6.97 s | 388 ms | 18.0x (SQLite-side wobble) |

Phases other than RANGE deliberately unchanged; run5→run6 deltas sit in
the read/noise band (`vsbench_run5.log`, `vsbench_run6.log`). vs campaign
start (run4): INSERT 16.1x→9.4x; COUNT 26.8x→17.6x; RANGE ~35x→19.3x;
PK point lookup 0.59x (VDB 1.7x AHEAD).

### Verification (from scratch)

- Clean `fpc -B` builds (sqltest 56,248; crashtest 45,229 lines).
- `sqltest` **2251/2251**, remaining=0 (`sqltest_p15b.log`).
- crashtest 8-way crash chain **8/8** (`c8_p15b.log`) — the
  `SyncWriteInterval=0` durability contract is unchanged.

---

## v0.008 — 2026-10-16 — Hız turu: P-18c literal INSERT hızlı şeridi (AST'siz yazım)

### Ne eklendi / değişti

- **P-18c — `ExecFastLiteralInsert` (VDbExecutor) + `ExecRaw` kancası
  (VDbSql):** `INSERT INTO t (kolonlar) VALUES (<literaller>)` biçimindeki
  cumleler artik lexer/AST/ExprEval zincirinden GECMIYOR — 31.9 µs/satır.
  Biçim tarayıcı yalnız şunları KABUL eder: ASCII tanımlayıcılar, kanonik
  tamsayı, '.'-lı float (`VDbFloatToStr(VDbParseFloat)` kanonik sonucu —
  genel yolla birebir), tek tırnaklı string (`''` kaçışı NextToken ile
  birebir), NULL (→ `''`, `EvalExpr` ile aynı), TRUE/FALSE (→ 'True'/'False',
  `CreateBool` ile aynı). Kolon listesi opsiyonel (yoksa genel yol gibi tüm
  tablo kolonları).
  **En ufak sapmada genel yol AYNEN devralır:** yorum, `?` param, fonksiyon,
  `+` işaret, `05`, bilimsel-basamaksız, BLOB, tırnaklı tanımlayıcı,
  `RETURNING`, `ON CONFLICT`, ikinci VALUES satırı, `;`, tablo yok, VIEW,
  INSERT tetikleyicisi olan tablo (STATEMENT+ROW, BEFORE+AFTER —
  `TriggersFor` propları), kolon/değer sayısı farkı.
  **Kabul yolunda genel yolun sarmalama dizisi birebir:** `RequirePriv`
  (R-18) → `RlsRequireInsert` (R-19) → `FT.Insert` (PK/UNIQUE/NOT NULL/
  CHECK/FK/AutoInc tablo katmanı — aynı yordam, aynı istisnalar, aynı sıra).
  F-21 sure ve R-24 sayaç kayıtları AST yoluyla kopyalandı; RET yolunda
  kayıt YAPILMAZ (genel yol kendi kaydeder — bkz. aşağıdaki düzeltme).
- **Düzeltme (A/B sırasında bulundu):** kanca ilk halinde `finally`
  içinde kayıt yaptığı için şeridin REDDETTİĞİ INSERT'ler `SHOW STATS`
  sayaçlarına iki kez yazılıyordu (sqltest logunda komut toplamı
  6811→6984). Kayıt artık yalnız kabul ve istisna yollarında; sayaç
  toplamı tekrar tabanla eşit (`sqltest_p18d.log` 6811 = `sqltest_p18.log`).
- **Bilinçli dokunulmayan:** `TriggersFor` içindeki debug `WriteLn`
  izleri (F-36 döneminden kalma, HEAD'de mevcut) — şerit başına 2 ekstra
  print üretmesi yalnız stdout gürültüsüdür; başka oturumun aktif hata
  ayıklama izine dokunulmadı.

### Ölçülmüş sonuç — bench26 mini A/B (200K satır, C:\temp, sıralı)

| Aşama | v0.007 (önce) | P-18c | Değişim |
|---|---|---|---|
| INSERT /satır | 51.4 µs | **31.9 µs** | **−%38** |
| INSERT toplam (tx) | 10.29 sn | **6.38 sn** | −38% |
| UPDATE / DELETE / okuma | — | — | değişmedi (yol dışı) |

v0.005 HEAD'e göre kümülatif INSERT: 52.4 → **31.9 µs** (−%39).
vsbench 1M ölçeğinde tahmini INSERT oranı 16.1x → ~10x (run5'te doğrulanacak).

### Doğrulama (sıfırdan)

- `fpc -B` temiz (sqltest 56.168; crashtest 45.149 satır).
- `sqltest` **2251/2251**, kalan=0 (`sqltest_p18d.log`); SHOW STATS
  komut toplamı tabanla birebir.
- crashtest 8'li çarpma zinciri **8/8** (`c8_p18d.log`) —
  `SyncWriteInterval=0` dayanıklılık sözleşmesi değişmedi.

---

## v0.008 — 2026-10-16 — Speed round: P-18c literal INSERT fast lane (AST-free writes) (ENGLISH)

### Added / changed

- **P-18c — `ExecFastLiteralInsert` (VDbExecutor) + `ExecRaw` hook
  (VDbSql):** statements shaped exactly like
  `INSERT INTO t (cols) VALUES (<literals>)` no longer pass through the
  lexer/AST/ExprEval chain — 31.9 µs/row. The format scanner ONLY accepts:
  ASCII identifiers, canonical integers, '.'-floats (canonicalized via the
  same `VDbFloatToStr(VDbParseFloat)` the parser uses), single-quoted
  strings (`''` escape identical to NextToken), NULL (→ `''`, same as
  `EvalExpr`), TRUE/FALSE (→ 'True'/'False', same as `CreateBool`). The
  column list is optional (missing = all table columns, like the general
  path).
  **Any deviation falls back to the untouched general path:** comments,
  `?` parameters, functions, `+` sign, `05`, exponent-without-dot, BLOB,
  quoted identifiers, `RETURNING`, `ON CONFLICT`, second VALUES row, `;`,
  missing table, VIEW, tables with INSERT triggers (STATEMENT+ROW,
  BEFORE+AFTER via `TriggersFor` probes), column/value count mismatch.
  **On the accepted path the general path's wrapper sequence is
  reproduced exactly:** `RequirePriv` (R-18) → `RlsRequireInsert` (R-19) →
  `FT.Insert` (PK/UNIQUE/NOT NULL/CHECK/FK/AutoInc live in the table layer
  — same routine, same exceptions, same order). F-21 timing and R-24
  command counters are replicated from the AST path; on REJECT nothing is
  recorded (the general path records its own run — see the fix below).
- **Fix (found during A/B):** the hook first recorded counters in a
  `finally` block, so lane-REJECTED INSERTs were counted TWICE in
  `SHOW STATS` (command total 6811→6984 in the sqltest log). Recording now
  happens only on accept and exception paths; the total again matches the
  baseline (`sqltest_p18d.log` 6811 = `sqltest_p18.log`).
- **Deliberately untouched:** debug `WriteLn` traces inside
  `TriggersFor` (left over from the F-36 era, present in HEAD) — the
  lane's two extra probes only add stdout noise; another session's active
  debugging trace was not removed.

### Measured — bench26 mini A/B (200K rows, C:\temp, sequential)

| Phase | v0.007 (before) | P-18c | Change |
|---|---|---|---|
| INSERT /row | 51.4 µs | **31.9 µs** | **−38%** |
| INSERT total (tx) | 10.29 s | **6.38 s** | −38% |
| UPDATE / DELETE / reads | — | — | unchanged (off-lane) |

Cumulative vs v0.005 HEAD: INSERT 52.4 → **31.9 µs** (−39%).
Expected 1M-scale vsbench INSERT ratio 16.1x → ~10x (to be confirmed by run5).

### Verification (from scratch)

- Clean `fpc -B` builds (sqltest 56,168; crashtest 45,149 lines).
- `sqltest` **2251/2251**, remaining=0 (`sqltest_p18d.log`); SHOW STATS
  command total matches the baseline exactly.
- crashtest 8-way crash chain **8/8** (`c8_p18d.log`) — the
  `SyncWriteInterval=0` durability contract is unchanged.

---

## v0.007 — 2026-10-16 — Hız turu: P-18a sıfır-kopya agreg taraması (ScanRawIter)

### Ne eklendi / değişti

- **P-18a — `ScanRawIter` (VDbCore/VDbTable/VDbExecutor)**: `TryStreamAgg`
  (COUNT/SUM/AVG/MIN/MAX akışı) artık `ScanAll` ile satır başına TBytes +
  Keys/Vals dizisi MALZELLEŞTİRMİYOR. `TVDb.ScanRawIter` ScanSnapshot'ın üç
  fazını (görünürlük + tombstone + R-26 filtresi + bucket toplu okuma +
  bozuk-kayıt sessiz atlama + şifre çözme) BİREBİR kopyalar; tek fark: değer,
  2 MB'lık chunk tamponunun içindeki aralıktan geri çağrıya `(PByte, Len)`
  olarak verilir. `VDbPeekRawRowP` aynı sınır kontrollerini kopyasız uygular.
  Şifreli kayıtlar nadir yol olarak çözülüp verilir (doğal gereklilik).
  Semantik birebir: eski-sema/bozuk kayıt veya hash çakışmasında aynı
  "genel yola düş" davranışı; sıralama bucket sırasıdır (agrega sıradan
  bağımsız). `Limit` desteklenmez (agregalar kullanmaz).
- `bench26` mini A/B: COUNT x5 140.8→**135.2 ms** (−%4), SUM x3
  144.9→**136.1 ms** (−%6) @200K. 200K ölçeğinde malzelleştirme büyük
  ölçüde cache-isabetli; asıl kazanç 1M'de (vsbench run5'te ölçülecek).
  Aynı koşuda INSERT/UPDATE yan aşamaları ±%5 gürültü gösterdi — mini-bench
  gürültülü makinede okuma fazları için alt sınırdır.

### Doğrulama (sıfırdan)

- `fpc -B` temiz (sqltest 55.856; crashtest 44.837 satır).
- `sqltest` **2251/2251**, kalan=0 (`sqltest_p18.log`).
- crashtest 8'li çarpma zinciri **8/8** (`c8_p18.log`) — dayanıklılık
  sözleşmesi (`SyncWriteInterval=0`) değişmedi.

---

## v0.007 — 2026-10-16 — Speed round: P-18a zero-copy aggregate scan (ScanRawIter) (ENGLISH)

### Added / changed

- **P-18a — `ScanRawIter` (VDbCore/VDbTable/VDbExecutor)**: `TryStreamAgg`
  (the COUNT/SUM/AVG/MIN/MAX stream) no longer materializes per-row TBytes +
  Keys/Vals arrays through `ScanAll`. `TVDb.ScanRawIter` copies ScanSnapshot's
  three phases BIT-FOR-BIT (visibility + tombstones + R-26 filter + bucketed
  bulk reads + silent skip of corrupt records + decryption); the only change:
  the value is handed to the callback as `(PByte, Len)` pointing INSIDE the
  2 MB chunk buffer. `VDbPeekRawRowP` applies the same bounds checks without
  copying. Encrypted records decrypt into a scratch buffer (rare path,
  inherent). Semantics preserved: old-schema/corrupt record or hash collision
  still falls back to the general path; iteration order is bucket order
  (aggregates are order-insensitive). `Limit` unsupported (aggregates don't).
- `bench26` mini A/B: COUNT x5 140.8→**135.2 ms** (−4%), SUM x3
  144.9→**136.1 ms** (−6%) @200K. At 200K the materialization mostly hits
  cache; the real win shows at 1M (to be measured in vsbench run5). Same run
  showed ±5% noise on unrelated phases — on a noisy machine the mini-bench is
  a lower bound for read phases.

### Verification (from scratch)

- Clean `fpc -B` builds (sqltest 55,856; crashtest 44,837 lines).
- `sqltest` **2251/2251**, remaining=0 (`sqltest_p18.log`).
- crashtest 8-way crash chain **8/8** (`c8_p18.log`) — the
  `SyncWriteInterval=0` durability contract is unchanged.

---

## v0.006 — 2026-10-16 — Hız turu: P-17 yazma-yolü tahsis diyeti (AutoInc, EncodeRow, Exists)

*Not: v0.005'te "P-16" reddedilen BETWEEN nokta-okuma adayıydı; karışmaması
için bu üçlü **P-17** olarak adlandırıldı.*

### Ne eklendi / değişti

- **P-17a — AutoInc sayacı ayri sözlük** (`VDbTable.pas`): sayaci ilerleten her
  INSERT (acik artan PK dahil) tum `TTableDef` kaydini `FTables`'a geri yaziyordu.
  Artik sayaç `TableId`-anahtarli O(1) sozlukte; sema kaydi sicak yolda DOKUNULMAZ.
  `SaveSchema` ayni alana `max(kayit, sozluk)` yazar (wire format degismedi);
  sozluk transaction snapshot'ina dahildir (ROLLBACK guvenli) ve DROP TABLE'da
  temizlenir. View yollari eski gibi kayit alanini kullanir (max() iki kaynagi da
  dogru temsil eder).
- **P-17b — `EncodeRow` tek tampon + ASCII hizli yolu** (`VDbTable.pas`): satir
  basina ~10-13 dinamik dizi tahsisi kaldirildi; alanlar tek buyuyen tampona
  yazilir. Saf-ASCII metin kaynak diziden dogrudan tasinir (UTF8Encode cikisi
  bayt bayt ayni olurdu); ASCII-ustu ve BLOB yollari birebir korundu.
  **Wire format bayt bayt ayni** — DecodeRow/CRC/reopen testleri yeni hali bilmiyor.
- **P-17c — cakisma denetiminde `Exists` devre-kesmesi** (`Insert`/
  `InsertReturning`/`UpsertRowReturning`): `Get` degeri (TBytes) ayirip cok
  atiyordu; `ExistsSnapshot` saf aramadir (pending+index+tombstone, O(1)).
  Anahtar gercekten varsa deger okunur ve "duplicate vs hash carpismasi"
  siniflandirmasi aynen korunur.

### Ölçülmüş sonuç — bench26 mini A/B (200K satir, C:\temp, ayni makine, ardişik)

| Asama | HEAD (once) | +P-17a/c | +P-17b (final) | Toplam |
|---|---|---|---|---|
| INSERT /satir | 52.4 µs | 51.4 | **50.1** | **−%4.5** |
| UPDATE /islem | 66.6 µs | 65.8 | **65.6** | −%1.5 |
| DELETE /islem | 47.5 µs | 45.0 | **45.0** | **−%5** |
| COUNT / SUM / PK / RANGE | — | — | — | degismedi (okuma yolu) |

Dürüst yorum: toplam kazanç ~%5 — tahsis diyeti beklenenden küçüktü. INSERT'in
kalan agirligi **parser (~12 µs)** ve **KV/commit katmaninda (~16 µs)**; sonraki
turlar oraya hedefleniyor. `bench26.dpr` (yeni) bu A/B'yi ~1 dakikada tekrarlama
araci olarak depoya girdi.

### Bilinçli olarak YAPILMAYANLAR

- **Plan cache — hâlâ ERTELENDİ** (v0.005 kararı): SQLite'in da prepared
  statement kullanmadığı görüldü (vsbench `sqlite3_exec` kullanıyor); plan
  cache'in önceliği düştü, önce ham pipeline diyeti.
- AutoInc sözlüğü DROP sonrası Temizlenir ama id yeniden kullanımına karsı
  FNextId zaten koruyor; ek denetim eklenmedi.

### Doğrulama (sıfırdan)

- `fpc -B` derlemeleri hatasız (sqltest 55.517 satır; crashtest 44.498 satır).
- `sqltest` **2251/2251**, kalan=0 (`sqltest_p16.log`).
- crashtest 8'li çarpma zinciri **8/8** "copme sonrasi veri kaybi/bozulma YOK"
  (`c8_p16.log`) — `SyncWriteInterval=0` dayanıklılık sözleşmesi değişmedi.

---

## v0.006 — 2026-10-16 — Speed round: P-17 write-path allocation diet (AutoInc, EncodeRow, Exists) (ENGLISH)

*Note: in v0.005 "P-16" was the REJECTED BETWEEN point-read candidate; to avoid
confusion this trio is named **P-17**.*

### Added / changed

- **P-17a — AutoInc counter in a side dictionary** (`VDbTable.pas`): every INSERT
  advancing the counter (including explicit ascending PKs) rewrote the whole
  `TTableDef` record back into `FTables`. The counter now lives in an O(1)
  dictionary keyed by `TableId`; the schema record is untouched on the hot path.
  `SaveSchema` writes `max(record, dict)` into the same field (wire format
  unchanged); the dictionary is part of the transaction snapshot (ROLLBACK-safe)
  and is cleaned on DROP TABLE. View paths keep using the record field — max()
  represents both sources correctly.
- **P-17b — `EncodeRow` single buffer + ASCII fast path** (`VDbTable.pas`): the
  ~10-13 dynamic-array allocations per row are gone; fields are written into one
  growing buffer. Pure-ASCII text is moved straight from the source string (the
  UTF8Encode output would be byte-identical); non-ASCII and BLOB paths preserved
  bit-for-bit. **Wire format byte-identical** — DecodeRow/CRC/reopen tests are
  unaware of the change.
- **P-17c — `Exists` short-circuit in the duplicate check** (`Insert` /
  `InsertReturning` / `UpsertRowReturning`): `Get` used to allocate the value
  (TBytes) just to throw it away; `ExistsSnapshot` is a pure lookup
  (pending+index+tombstone, O(1)). The value is read only when the key actually
  exists, preserving the "duplicate vs hash collision" classification exactly.

### Measured — bench26 mini A/B (200K rows, C:\temp, same machine, sequential)

| Phase | HEAD (before) | +P-17a/c | +P-17b (final) | Total |
|---|---|---|---|---|
| INSERT /row | 52.4 µs | 51.4 | **50.1** | **−4.5%** |
| UPDATE /op | 66.6 µs | 65.8 | **65.6** | −1.5% |
| DELETE /op | 47.5 µs | 45.0 | **45.0** | **−5%** |
| COUNT / SUM / PK / RANGE | — | — | — | unchanged (read path) |

Honest reading: the allocation diet paid ~5% in total — less than hoped. The
remaining INSERT weight sits in the **parser (~12 µs)** and the
**KV/commit layer (~16 µs)**; that is where the next rounds aim. `bench26.dpr`
(new) is committed as the ~1-minute A/B harness.

### Deliberately NOT done

- **Plan cache — still DEFERRED** (v0.005 decision): the SQLite side of vsbench
  turned out to use `sqlite3_exec` (no prepared statements either), lowering the
  priority of a plan cache vs raw pipeline diet.
- The AutoInc dictionary is cleaned on DROP; no extra guard against TableId reuse
  was added since FNextId already prevents it.

### Verification (from scratch)

- `fpc -B` builds clean (sqltest 55,517 lines; crashtest 44,498 lines).
- `sqltest` **2251/2251**, remaining=0 (`sqltest_p16.log`).
- crashtest 8-way crash chain **8/8** "no data loss/corruption after crash"
  (`c8_p16.log`) — the `SyncWriteInterval=0` durability contract is unchanged.

---

## v0.005 — 2026-10-16 — Hız turu: P-14/P-15 + adil kıyas (vsbench) + ölü kod temizliği

### Ne eklendi / değişti

- **P-14a — tahsis-siz `VDbNorm` hızlı yolu + `IsView` tek `TryGetValue`**
  (`VDbTable.pas`): ASCII-üstü/büyük harf/kabartma içermeyen dizilerde
  `Trim+LowerCase` hiç çağrılmıyor, aynı referans dönüyor (davranış bit-bit aynı;
  FPC `Trim`'in yalnız ' ' ve #9 sildiği `ttrim.pas` ile doğrulandı). Sema/kolon
  aramaları satır başına ~15 kez bu fonksiyondan geçiyor.
- **P-15a — `SortIdxEntries` decorated INT sort** (`VDbTable.pas`): INTEGER
  indeks anahtarları karşılaştırma başına yeniden parse edilmek yerine bir kez
  Int64'a çözülüp dekorlu anahtarla sıralanıyor; NULL-en-önde sıra ve
  `CompareStr(Pk)` tie-break birebir korundu; parse edilemeyende eski yola düşer.
  Lazy PK index rebuild 300K'da **2123 → 892 ms**; RANGE sorgularının kök
  nedeni bu tek-seferlik rebuild'miş (sorgu başına 25 ms sanılıyordu).
- **P-12 `TryStreamAgg`** (`VDbExecutor.pas`) ve **P-13 `ScanSnapshot` toplu
  okuma + counting-sort bucket** (`VDbCore.pas`): agregatlarda satır matrisi
  malzelleştirmesi yok; taramada satır başına 3 syscall yerine bucket başına tek
  toplu okuma.
- **R-26 tablo-tarama filtresi** kodla bu turda yayımlandı (ayrıntı v0.004).
- **`vsbench.dpr` (yeni): SQLite ile ADİL hız testi** — 1M satır, aynı SQL metni,
  aynı disk, tek süreç, iki taraf da stok varsayılanlar (VDB `SyncWriteInterval=0`
  = senkron commit; SQLite varsayılan journal modu). Çalıştırmak için `sqlite3.dll`
  exe'nin yanında olmalı. **Sonuçlar aşağıda dürüst haliyle yazılı.**
- **Ölü kod temizliği** (`VDbExecutor.pas`, `VDbSql.pas`, `VDbTable.pas` ve
  yardımcı dosyalar): kullanılmayan yordam/birim parçaları kaldırıldı; davranış
  değişmedi (aşağıdaki gauntlet sıfırdan doğruladı).

### Ölçülmüş sonuç — adil kıyas run3 → run4 (1M satır)

| Aşama | run3 VDB | run4 VDB | SQLite | VDB/SQLite (run4) |
|---|---|---|---|---|
| INSERT 1M (tx) | 56.4 sn | 59.7 sn | 3.70 sn | 16.1x |
| COUNT(*) x10 | 1.06 sn | 1.20 sn | 44.8 ms | 26.8x |
| SUM(bakiye) x5 | 1.10 sn | 1.35 sn | 94.4 ms | 14.3x |
| SELECT PK 50K | 1.95 sn | **2.51 sn** | 3.53 sn | **0.71x — VDB hızlı** |
| RANGE 2000x100 | 12.3 sn | **8.54 sn** | 245 ms | **34.9x** (55x'ten indi) |
| UPDATE 100k | 7.4 sn | 8.59 sn | 318.8 ms | 26.9x |
| DELETE 100k | 5.2 sn | 6.10 sn | 229.7 ms | 26.6x |

- Doğrulama: iki motorun COUNT/SUM'ı eşit (5.000.000.000), DELETE sonrası 900.000.
- Kalan boşluk **mimari**: SQLite prepared statement kullanıyor; P-14 mikro
  ölçeklerinde INSERT'imizin ~56 µs'si = parse ~12 + glue ~9 + Insert/commit ~16
  + sarmalayıcı ~3-5 + heap büyüme cezası ~15 µs.

### Bilinçli olarak YAPILMAYANLAR

- **P-16 nokta-okuma adayı — REDDEDİLDİ:** BETWEEN uçlarından `IntToStr` ile anahtar
  üretmek, INT PK'ların yazım şekliyle saklanması (`'010'` kalır) nedeniyle
  `'01000'` gibi satırları sessiz düşürürdü → semantik bozucu.
- **Plan cache — ERTELENDİ:** yürütücü AST'yi mutasyona uğratıyor (`Stmt.Table :=
  baseTable`, `Stmt.Body` sahiplik devri); önbellek ancak immutable-plan denetimiyle
  güvenli (v0.003 kararı yeniden doğrulandı).
- **Index-only COUNT — REDDEDİLDİ:** "veri bozuksa bağır" sözleşmesiyle çelişir.
- **P-15b peek-rebuild — SONRAKI ADAY:** `BuildPkIdx` hâlâ tam-decode `ScanRows`
  kullanıyor (~620 ms @300k); stream/peek rebuild orta riskli, ayrıca plan cache
  ile birlikte değerlendirilecek.

### Doğrulama (ölü kod temizliği sonrası SIFIRDAN)

- `fpc -B` derlemeleri hatasız (sqltest 55.383 satır; crashtest 44.364 satır).
- `sqltest` **2251/2251**, kalan=0, KESILDI yok (`sqltest_restart.log`).
- crashtest 8'li çarpma zinciri **8/8** "copme sonrasi veri kaybi/bozulma YOK"
  (`c8_restart.log`) — `SyncWriteInterval=0` dayanıklılık sözleşmesi değişmedi.

---

## v0.005 — 2026-10-16 — Speed round: P-14/P-15 + fair benchmark (vsbench) + dead-code cleanup (ENGLISH)

### Added / changed

- **P-14a — allocation-free `VDbNorm` fast path + single `TryGetValue` in `IsView`**
  (`VDbTable.pas`): strings without non-ASCII, uppercase or trim-requiring edge
  whitespace return the SAME reference — `Trim+LowerCase` is never called and
  behavior stays bit-identical (FPC `Trim` only strips ' ' and #9, verified with
  `ttrim.pas`). Schema/column lookups hit this ~15 times per row.
- **P-15a — decorated INT sort in `SortIdxEntries`** (`VDbTable.pas`): INTEGER index
  keys are decoded to Int64 once instead of re-parsed per comparison; NULL-first
  ordering and the `CompareStr(Pk)` tie-break preserved bit-for-bit; unparsable keys
  fall back to the legacy path. Lazy PK index rebuild at 300K: **2,123 → 892 ms**.
  The root cause of the RANGE gap turned out to be this one-time rebuild (previously
  mistaken for 25 ms per query).
- **P-12 `TryStreamAgg`** (`VDbExecutor.pas`) and **P-13 batched `ScanSnapshot` reads
  with counting-sort buckets** (`VDbCore.pas`): aggregates no longer materialize the
  row matrix; scans issue one batched read per bucket instead of 3 syscalls per row.
- **R-26 table-scan filter** shipped with this round (details in v0.004).
- **`vsbench.dpr` (new): FAIR speed test vs SQLite** — 1M rows, same SQL text, same
  disk, single process, both engines on stock defaults (VDB `SyncWriteInterval=0`
  = synchronous commit; SQLite default journal mode). Needs `sqlite3.dll` next to
  the exe. **Honest results below.**
- **Dead-code cleanup** (`VDbExecutor.pas`, `VDbSql.pas`, `VDbTable.pas` and helper
  files): unused routines/unit parts removed; behavior unchanged (gauntlet below
  re-verified from scratch).

### Measured — fair comparison run3 → run4 (1M rows)

| Phase | run3 VDB | run4 VDB | SQLite | VDB/SQLite (run4) |
|---|---|---|---|---|
| INSERT 1M (tx) | 56.4 s | 59.7 s | 3.70 s | 16.1x |
| COUNT(*) x10 | 1.06 s | 1.20 s | 44.8 ms | 26.8x |
| SUM(balance) x5 | 1.10 s | 1.35 s | 94.4 ms | 14.3x |
| SELECT PK 50K | 1.95 s | **2.51 s** | 3.53 s | **0.71x — VDB faster** |
| RANGE 2000x100 | 12.3 s | **8.54 s** | 245 ms | **34.9x** (down from 55x) |
| UPDATE 100k | 7.4 s | 8.59 s | 318.8 ms | 26.9x |
| DELETE 100k | 5.2 s | 6.10 s | 229.7 ms | 26.6x |

- Verification: COUNT/SUM identical across engines (5,000,000,000); 900,000 rows after DELETE.
- The remaining gap is **architectural**: SQLite uses prepared statements; our
  ~56 µs per INSERT breaks down as parse ~12 + glue ~9 + Insert/commit ~16 +
  wrapper ~3-5 + heap growth penalty ~15 µs (P-14 micro-benchmarks).

### Deliberately NOT done

- **P-16 point-read candidate — REJECTED:** generating keys with `IntToStr` from
  BETWEEN bounds would silently drop rows such as `'01000'`, since INT PKs are
  stored exactly as written (`'010'` stays). Semantics-breaking.
- **Plan cache — DEFERRED:** the executor mutates the AST (`Stmt.Table := baseTable`,
  `Stmt.Body` ownership transfer); a cache is only safe with an immutable-plan audit
  (v0.003 decision re-confirmed).
- **Index-only COUNT — REJECTED:** conflicts with the "shout if data is corrupt" contract.
- **P-15b peek-rebuild — NEXT CANDIDATE:** `BuildPkIdx` still full-decodes via
  `ScanRows` (~620 ms @300K); stream/peek rebuild is medium-risk, to be evaluated
  together with the plan cache.

### Verification (FROM SCRATCH after dead-code cleanup)

- Clean `fpc -B` builds (sqltest 55,383 lines; crashtest 44,364 lines).
- `sqltest` **2251/2251**, 0 remaining, no aborts (`sqltest_restart.log`).
- 8-crash crashtest chain **8/8** "no data loss/corruption after crash"
  (`c8_restart.log`) — the `SyncWriteInterval=0` durability contract unchanged.

---

## v0.004 — 2026-10-15 — Tablo-tarama filtresi (R-26): 240x hızlanma

### Ne eklendi

**R-26 — Tablo-tarama filtresi (Table-scan filter)** — `VDbCore.pas`, `VDbTable.pas`
- **Sorun:** `SELECT * FROM kucuk LIMIT 10` bir başkasındaki 150K satırlı
  tabloyı da okudu + çözdü + atıyor → 1.782 ms → **743x yavaş**.
- **Çözüm:** Her satırın `TableId`'si (ilk 2 bayt, little-endian) zaten
  `Recover`'da CRC için okunuyor ve `AppendRec`'te yazılıyor — buradan
  **bedava çıkar** ve `TDbLoc.TableId: Integer` alanına yazılır.
- `ScanSnapshot` / `ScanAll` artık opsiyonel `TableFilter: Integer`
  parametresi alır; `TableId >= 0` ve `TableId <> Filter` ise dosya
  okunmaz (en pahalı yol elenir).
- Dört çağrı sitesi (`ScanRowsPart`, `ALTER TABLE`, `RENAME TABLE`,
  `DROP TABLE`) `t.TableId` filtresi ile güncellendi.
- Şema kaydı (`VDB_SCHEMA_KEY = 0`) `VDB_SCHEMA_TAG = 'VSCH1'` ile
  tespit edilip `TableId := -1` atanır → filtre uygulanmaz, eski
  davranış **birebir korunur**.

### Ölçülmüş sonuç (aynı makine, autocommit/transaction karışık)

| Senaryo | Eski | Yeni | Kazanç |
|---|---|---|---|
| A=0, B LIMIT 10 | 2.4 ms | 2.3 ms | — |
| A=50K, B LIMIT 10 | 582 ms | 4.3 ms | **135x** |
| A=150K, B LIMIT 10 | 1.782 ms | **7.4 ms** | **240x** |

- Etiketler **aynı oturumda** (`AppendRec` yazar) VE **yeniden açmada**
  (`Recover` okur) doğru → uzun süreli sunucularda da geçerli.

### Speedtest (v0.004 sonrası) — VDB vs SQLite 3.54.0

| İşlem | VDB Fast (10ms) | SQLite WAL | Not |
|---|---|---|---|
| Batch INSERT 10K | 38K/sn | 1.5M/sn | SQLite WAL çok hızlı |
| **Multi-row VALUES (100/stmt)** | **57K/sn** | — | **1.5x batch** ✅ |
| Single INSERT (autocommit) | **16K/sn** | 51K/sn | **Group commit 16x** (eski 1K/sn) ✅ |
| SELECT PK (nokta) | 43K/sn | 338K/sn | — |
| **Range BETWEEN** | **401/sn** | 68K/sn | **Bottleneck** (string-matris materyalizasyonu) |
| UPDATE | 15K/sn | 53K/sn | — |
| DELETE | 20K/sn | 51K/sn | — |

- R-26 tek-tablo range'i iyileştirmez (diğer tablo filtresi yok);
  bottleneck burada **string-matris materyalizasyonu** (Aşama 3.1 hedefi).

### Değişen dosyalar

- `VDbCore.pas`: `TDbLoc.TableId`, `RowTagFunc` property, `AppendRec`,
  `Recover` (pendTag), `ScanSnapshot`/`ScanAll` filtre.
- `VDbTable.pas`: `VDbRowTagOf` callback, `TVTableDb.Create` ataması,
  4 `ScanAll` çağrısı filtreli.

### Doğrulama

- `sqltest` **2224 OK / 2 FAIL** (opsiyonel `vdboldtext.dll` /
  `vdbtestext.dll` eksik — önceden biliniyor). Yeni regresyon **yok**.

---

## v0.003 — 2026-10-14 — Performans turu: PK Lazy Index + Group Commit + SQLite kıyası

### Ne eklendi

**R-25 — PK Lazy Index** (`VDbTable.pas`, `VDbExecutor.pas`)
- PK kolonu üzerinde `T.Idx`'e dokunmadan tembel sıralı index kurulur
  (`FPkIdx` / `FPkIdxDirty` + `BuildPkIdx`).
- `TryGetMemIndex` PK kolonu için lazy index döndürür; kirli ise yeniden kurar.
- `IndexUsedByWhere` PK kolonunu tanır (`Ix := -2` → `<tablo>_pkey`);
  `if Length(Td.Idx) = 0 then Exit;` erken çıkışı kaldırıldı.
- **Etki:** `BETWEEN` / range sorguları Seq Scan yerine Index Scan kullanır.
  Range 26/sn → ~400/sn (**~15x**). `EXPLAIN` bunu `Index Scan using b_pkey`
  olarak gösterir.
- **Neden `T.Idx`'e otomatik PK index EKLENMEDİ:** testleri kırıyordu
  (`IndexNames`, indeks sayım testleri) ve `CheckConstraints` her INSERT'te
  `TryGetMemIndex` → `FlushIdxPending` → O(n log n) yeniden sıralama →
  35x yavaşlama üretiyordu.

**R-25 — Group Commit** (`VDbCore.pas`)
- `SyncWriteInterval` özelliği (PostgreSQL `commit_delay` benzeri, ms).
- `Put` / `Delete` / `Flush` / `CommitBatch` fsync kontrolü bu süreye bağlandı.
- **Kritik düzeltme:** `CommitBatch`'in de dahil edilmesi gerekti. Yalnız
  `Flush` güncellendiğinde kazanç ~%3 idi; `CommitBatch` dahil edilince
  UPDATE/DELETE gerçekten hızlandı.
- Varsayılan `0` = eski davranış (her yazmada fsync) — mevcut kod yolu
  davranışı **değişmez**.
- Dayanıklılık takası: `>0` ise en fazla o kadar ms gecikmeyle fsync;
  `FDirty` False bırakılmaz.

**Benchmark ve ölçüm araçları**
- `speedtest.dpr` — VDB vs SQLite 3.54.0 kıyası (aynı sema/veri/SQL).
  `ParamStr(1)` ile çalışma dizini; SQLite `sqlite3.dll` yanında olmalı.
  Çoklu VALUES satırı da içerir (aşağıda R-26).
- `parseprobe.dpr` — parse payını ölçer (yeni parser nesnesi vs saf parse vs tam Exec).
- `batchprobe.dpr` — tek satır vs çoklu VALUES.
- `layerprobe.dpr` — SQL katmanı / tablo katmanı ayrıştırması.

### Ölçülmüş sonuçlar (aynı makine, transaction içi)

| Katman / yol | Sonuç |
|---|---|
| Parse payı (nokta SELECT) | 4,7 µs/is = **%43** (tam Exec 10,9 µs) |
| Yazma yolu分解 (20K satır) | Tam yol 26,6 µs/satır; tablo katmanı 11,8 µs/satır → **SQL katmanı %56** |
| ÇOKLU VALUES (100/stmt) | 36K → **55K satır/sn (1,5x)** |

**VDB vs SQLite (en iyi modlar):** VDB group-commit UPDATE 15K/sn, DELETE 20K/sn
— SQLite'ın **kendi varsayılan dayanıklı moduna** (54-55/sn) karşı 280-370x.
Ama SQLite WAL'e (50K/sn yazma, 289K/sn nokta SELECT) karşı geride.

### Bilinçli olarak YAPILMAYANLAR (ölçülüp reddedilen)

- **AST / statement cache — REDDEDİLDİ.** Yürütücü AST'yi değiştiriyor:
  VIEW DML'de `Stmt.Table := baseTable` (VDbExecutor ~6561/7056/7307),
  CREATE TABLE'da `Stmt.Checks := ...` (~7538), trigger/function'da
  `Stmt.Body := nil` sahiplik devri (~8189). Cache'leme ikinci çalıştırmada
  bozardı. `EvalExpr` literal yolu zaten hızlı (`Exit(lit.AsString)`).
- **Tetik/RLS döngü-hoist — REDDEDİLDİ.** Kazanç küçük (boşken zaten hızlı
  çıkıyor) ama semantik risk var (tetik listesi satır başına yeniden
  değerlendiriliyor). Değmez.
- **Tip-değer yazma yolu — yapılmadı.** 11,8 µs/satır tabanı string-KV;
  altına inmek storage'ı tip-binary'a çevirmek demek (motorun yeniden yazımı).

### Diğer güncellemeler
- `quickbench.dpr` — `DROP TABLE IF EXISTS` (eski sabit `C:\temp\qb` hatası),
  group-commit benchmark satırları.
- `yol_haritasi.md` — R-25 eklendi (FAZ 2, kanıt satırı, §5.16 tarihçe).
- `SQL.md` — `EXPLAIN ... BETWEEN` → `Index Scan using <tablo>_pkey`.
- `docs/01-MOTOR.md` — VDbCore (SyncWriteInterval), VDbTable (PK lazy index),
  VDbExecutor (IndexUsedByWhere PK desteği).
- `docs/02-DOSYA-FORMATI.md` — §4 commit-flush → group commit.
- `README.md` — girişe PK Lazy Index + Group Commit.

### Doğrulama
- `sqltest` **2224 OK / 2 FAIL** (opsiyonel `vdboldtext.dll` / `vdbtestext.dll`
  eksik — önceden biliniyor). Yeni regresyon **yok**.

---

## v0.002 — Temel özellik turu (özet)

Motorun SQL/özellik kapsamını genişleten ve kararlı hâle getiren turlar
(ayrıntılar `yol_haritasi.md` §3-§5):

- R-12 Connection Pool + TCP SQL sunucusu (VDBS) — tam
- R-13 Partitioning, R-14 Parallel Query, R-15 Cost-Based Optimizer
- R-16 WAL Arşivleme + PITR, R-17 Streaming Replication (dosya + TCP)
- R-18 RBAC, R-19 Row Level Security, R-20 ICU Collation
- R-21 Extension/Plugin, R-22 CREATE INDEX CONCURRENTLY
- R-23 Cross-Platform C API, R-24 SHOW STATS
- MVCC, SAVEPOINT, UPSERT, RETURNING, Trigger, View, Stored Procedure,
  JSONB, Spatial, Range, CDC, TimeTravel, şifreleme (AES-256 + PBKDF2)

---

## v0.001 — İlk sürüm

Tek dosyada çalışan, append-only KV üzerine kurulmuş ilişkisel çekirdek
(`VDbCore` + `VDbTable`), SQL katmanı (`VDbParser` / `VDbAst` /
`VDbExecutor` / `VDbSql`), WAL, şifreleme, `TDataSet` köprüsü.
