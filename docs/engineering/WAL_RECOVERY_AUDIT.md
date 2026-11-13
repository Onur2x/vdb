# WAL ve Kurtarma Denetimi (PHASE-2 / p2-wal-audit)

Tarih: 2026-11-14
Durum: Denetim tamamlandi. Bulgular kod kanitiyla asagidadir.

> Bu belge bir **denetim ve bosluk kaydidir**. "Production-ready" iddiasi
> icermez. Asagidaki tablolarda `KOD` = davranis kaynak kodda dogrulandi,
> `TEST` = otomatik kapi ile dogrulandi, `BOSLUK` = dogrulanmadi.

---

## 1. Kapsam

VDB'de kalicilik/wal yuzeyi **iki ayri sistemden** olusur ve ikisi de
aktiftir. Ucuncu bir birim olu kod olarak bulundu.

| Birim | Amac | Kullaniliyor mu |
|---|---|---|
| `VDbPageWal.pas` (`TVDbPageWal`) | v3 **sayfa imajli** WAL (`.wal`, `VWL3`) | Evet — sayfa motorunun (VDbPageStore) kalicilik yolu |
| `VDbCore.pas` (`WriteAheadWAL`/`ReplayWAL`) | **KV kayit defteri** WAL (`.wal`, `WALR`) | Evet — `Core_VdbWalWrite` / `Core_VdbWalReplay` (vdbapi/DLL) |
| `VDbWal.pas` | eski "temel iskelet" | **HAYIR — olu kod** |

Kanit (grepsel): `unit VDbWal;` disinda depoda tek bir referans yok
(`*.pas`, `*.lpr`, `*.dpr`, `*.lpi`, `*.md` tarandi; tek eslesme birimin
kendi `unit` satiri). Bu birim **kaldirildi** (bkz. §7).

Denetim kapsami: commit/fsync invariant'lari, kayit formati ve sinir
dogrulamalari, torn-tail/CRC/LSN durumlari, kurtarma idempotentligi,
checkpoint budama guvenligi, kilit sirasi, crash matrix.

---

## 2. Sayfa WAL (`VDbPageWal.pas`) — bicim

Dosya duzeni:

```
[0 .. 4095]  baslik (4096 B)
  magic 'VWL3' ($334C5756) | surum (1/2) | sayfa boyu | checkpoint LSN | CRC
  flags (ENC biti) | keycheck (16 B) | salt (16 B) | db kimligi (16 B)
[4096 ..]    kayitlar, her biri 20 B baslik:
  Magic(4) | LSN(4) | PayloadLen(4) | PageNo(4) | Crc(4)
```

* `PayloadLen = 4096` → sayfa cercevesi (`VFW1`), sifreli modda
  `VDB_ENC_ENVELOPE` uzunlugu.
* `PayloadLen = 0`, `PageNo = 0` → commit isareti (`FWC1`).
* Surum 2'de kayit CRC'si **yalniz 20 baytlik basligin ilk 16 bayti**
  uzerinden hesaplanir; yuk butunlugu sayfanin kendi `PageSeal`/CRC'si
  ile tasinir. (Surum 1 geriye uyumlu okunur.)

## 3. Sayfa WAL — invariant tablosu

| # | Invariant | Durum | Kanit / Not |
|---|---|---|---|
| W1 | Commit onayindan once kayitlar + commit isareti fsync edilir | KOD | `Commit(DoSync=True)` → tek `WriteBuffer` sonrasi `VDbFlushStream` |
| W2 | fsync hatasinda commit geri alinir (hayalet commit yok) | KOD + TEST | `FStream.Size := startPos` geri kirpma; `DebugSetSyncFault` ile test edilir (`wal_crash_matrix`) |
| W3 | Yazim hatasinda dosya geri kirpilir, tampon korunur | KOD | Ayni blok; hata yeniden firlatilir |
| W4 | Kayitta magic + surum + uzunluk + LSN + CRC + tip var | KOD | 20 B baslik + baslik sayfasi alanlari |
| W5 | Sinir dogrulamasi (`PayloadLen > 65536` reddi) | KOD + TEST | Recover icinde `TornTail` + dur |
| W6 | Kesik/eksik baslik → `TornTail`, onceki commit'ler korunur | KOD + TEST | 20 B okunamazsa dur |
| W7 | Bozuk magic → dur | KOD + TEST | `VFW1`/`FWC1` degilse `TornTail` |
| W8 | Bozuk CRC → o noktada dur | KOD + TEST | CRC karsilastirmasi |
| W9 | Ayni sayfa icin son cerceve kazanir | KOD + TEST | `pending` haritasi dedup |
| W10 | Meta sayfa (0) EN SON uygulanir | KOD + TEST | `AppliedPages` sirasi; dosya uzatma tutarliligi |
| W11 | Kurtarma idempotent | KOD + TEST | Iki kez `Recover` ayni sonucu verir |
| W12 | Checkpoint budama yalniz guvenliyse yapilir | KOD + TEST | `WalBodySafeToPrune`: tum LSN ≤ checkpoint degilse **hicbir sey** yapilmaz |
| W13 | Truncate sonrasi baslik LSN'i ve `HasContent=False` | KOD + TEST | Yeniden baslik yazimi + fsync |
| W14 | WAL dosyasi asla silinmez, yalniz kirpilir | KOD | Handle gecerliligi korunur (cok-surecli) |
| W15 | `WrittenLsn` yalniz ileri gider | KOD | Regresyon, bekleyen `AwaitDurable` erken cikisini onler |
| W16 | Kilit sirasi: yazim `FWriteCs` → fsync `FSyncCs`, fsync kilit disinda | KOD | Grup commit amaci |
| W17 | Artimsal tarama yalniz baslik LSN'i degismediyse | KOD | Aksi halde tam tarama |
| W18 | Sifreli WAL: yuk `VDbPageOpen` ile cozulur, cozulemezse hata | KOD | Sessiz atlama yok |
| W19 | Disk-dolu / izin hatasi icin gercek simulasyon | **BOSLUK** | Yalniz fsync-fault kancasi var; gercek `ENOSPC` testi yok |
| W20 | LSN wraparound testi | **BOSLUK** | 32-bit LSN; sarmalanma senaryosu test edilmiyor |
| W21 | Ertelenmis fsync (`Commit(False)` + `SyncDurable`) hayalet commit'i engeller | KOD | `FUnsyncedStartPos` geri kirpma |

## 4. KV WAL (`VDbCore.pas`) — invariant tablosu

| # | Invariant | Durum | Kanit / Not |
|---|---|---|---|
| K1 | Her yazim sonrasi fsync (write-ahead durability) | KOD | `VDbFlushStream(fs)` |
| K2 | Dosya varsa sona eklenir (kirpilmaz) | KOD | `fmOpenReadWrite`; eski `fmCreate` hatasi duzeltilmis |
| K3 | Kayit CRC'si (LSN + stamp + key + uzunluk + flags + yuk) | KOD + TEST | `RecCrcWal` |
| K4 | DEL kaydi deger tasimaz | KOD + TEST | `ValLen = 0` zorunlu |
| K5 | `ValLen > VDB_MAX_VALUE` reddi | KOD + TEST | |
| K6 | Ilk bozuk kayitta durur; oncesi uygulanir | KOD + TEST | Off-by-one duzeltmesi |
| K7 | Replay kendini yeniden WAL'e yazmaz (`SkipWAL`) | KOD | Dongu onlenir |
| K8 | Replay sonunda `BATCHEND` yazilir ve commit edilir | KOD | Aksi halde replay geri sarilirdi |
| K9 | Basarili replay `.wal` dosyasini siler | KOD | Bozuk kuyruk da silinir (uygulanamaz) |
| K10 | Ikinci replay idempotent (dosya yok → `True`, veri degismez) | KOD + TEST | |
| K11 | Otomatik WAL acikken cift uygulama riski | **BOSLUK** | `SetWALEnabled` bunu yorumda uyariyor; engelleyici kod yok |
| K12 | WAL boyutu/retention siniri | **BOSLUK** | Sinir yalniz `FArchiveDir` verilmisse (rotation); varsayilan sinirsiz buyume |
| K13 | WAL at-rest sifreleme | **BOSLUK** | KV WAL **sifrelenmez**; hassas deger duz metin olarak `.wal`'de durur |

## 5. Crash matrix (skill §4.2)

| Kesinti noktasi | Beklenen | Sayfa WAL | KV WAL | Test |
|---|---|---|---|---|
| WAL kaydi yazilmadan once | Commit yok | Tutarli | Tutarli | `wal_crash_matrix` (commit'siz kuyruk) |
| WAL kaydi yazildi, commit isareti yok | Commit yok, kuyruk atilir | KOD+TEST | KOD+TEST | Evet |
| Commit isareti yazildi, fsync yok | Belirsiz → geri kirpilir | KOD+TEST | — (her yazim fsync) | Evet (`SyncFault`) |
| fsync sonrasi | Commit kalici | KOD | KOD | Dolayli |
| Sayfa yazimindan once/sonra | WAL'den yeniden uygulanir | KOD+TEST | n/a | Evet |
| Sayfa yazimi ortasinda (torn page) | Sayfa CRC'si tutmaz → WAL son kazanir | KOD | n/a | Dolayli |
| Checkpoint metadata vs tamamlanma | Guvenli degilse budanmaz | KOD+TEST | — | Evet |
| Yedek snapshot vs manifest | Yedek tarafi bu denetimin disinda | BOSLUK | BOSLUK | Yok |
| Replikasyon send/ack | Replikasyon yolu bu denetimin disinda | BOSLUK | BOSLUK | Yok |

Kurtarma sonrasi genel invariant (skill §4.2): commit edilmis kaybolmaz,
commit edilmemis gorunmez, kurtarma **biter ya da acik hata verir** —
sessiz yarim durum yok. Sayfa WAL'de sifre cozumleme hatasi `raise` eder
(W18); KV WAL'de bozuk kayit sessizce yutulmaz, kesilir ve sayilir.

## 6. Kalan riskler (durust liste)

1. **KV WAL sifrelenmemis.** Sayfa WAL `SetEncryptionKey` ile at-rest
   sifreleme sunar; KV WAL duz metindir. Hassas deger yazan kurulumlarda
   `.wal` dosyasi diskte acik metin birakir. Bu, skill §4.1'in
   "WAL hassas veri icerebilir" maddesi karsisinda **acik bosluktur**.
2. **KV WAL sinirsiz buyume.** `FArchiveDir` verilmezse rotation yok;
   `.wal` yalniz basarili replay'de silinir. Uzun sureli WAL kullaniminda
   disk tuketimi ongorulemez.
3. **Cift uygulama riski (KV).** `SetWALEnabled` otomatik WAL acikken
   replay kayitlarinin iki kez uygulanabilecegini belirtiyor; koruyucu
   kod yok.
4. **Gercek disk-dolu (ENOSPC) testi yok.** Yalniz fsync-fault kancasi
   (`DebugSetSyncFault`) var; `ENOSPC`, izin reddi ve gecici I/O hatasi
   senaryolari otomatik kapida temsil edilmiyor.
5. **LSN wraparound.** LSN 32-bit `LongWord`; sarmalanma ve `MinLSN`
   karsilastirmalari test edilmedi.
6. **Tek yazici siniri.** Sayfa WAL tek yazici varsayar; cok-surecli
   yazim `VDbLockStream` ile disipline edilir, ancak es zamanli
   writer/checkpoint/backup sirasi otomatik test edilmiyor.
7. **Yedek ve replikasyon** crash noktalari bu denetimde kapsanmadi.

## 7. Yapilan degisiklik

* `VDbWal.pas` **silindi**. Gerekce: sifir referans (olu kod) ve
  kullanildigi takdirde sessiz veri kaybi uretecek govde
  (`WalWriteAhead` her cagride dosyayi `fmCreate` ile kirpiyor,
  `Crc := 0` yaziyor; `WalReplay` `Result := False`; `WalCheckpoint`
  dogrudan `DeleteFile`).
* **Kirilma etkisi:** Yok. Birim dis API yuzeyinde degil, hicbir `.lpi`,
  `.lpr`, `.dpr` veya kaynak tarafindan `uses` edilmiyordu.
* Yeni kalici kapi: `tests/wal_crash/wal_crash_matrix.lpr` (sayfa WAL)
  ve `tests/wal_crash/kv_wal_matrix.lpr` (KV WAL). Bu kapilar §3/§4'te
  `TEST` olarak isaretlenen satirlarin kanitidir ve regresyon olarak
  kosulmaya devam eder.

### 7.1 Kapi sonuclari (2026-11-14)

* `wal_crash_matrix`: **41 passed / 0 failed**. Kapsam: commit'li
  cerceveler uygulanir, commit'siz kuyruk atilir, kesik baslik
  (TornTail), CRC bozulmasi, bozuk magic, gecersiz PayloadLen, iki kez
  kurtarma (idempotent), ayni sayfa icin son commit kazanir, meta sayfa
  en son uygulanir, fsync hatasinda commit basarisiz + hayalet commit
  yok, guvenli olmayan budama reddedilir, guvenli budama
  (`Bytes=4096`, `HasContent=False`, `HeaderLsn`), yanlis veritabani
  kimligi reddi, `CommitCount`.
* `kv_wal_matrix`: **32 passed / 0 failed**. Kapsam: yaz/say/replay +
  `.wal` silme, yeniden acilista kalicilik, ikinci replay idempotent,
  yarim kayit (onceki kayit uygulanir, sonraki atilir), CRC ve magic
  bozulmasinda hicbir kayit uygulanmaz, DEL kaydi deger tasiyamaz,
  `VDB_MAX_VALUE` ustu deger reddi.
* Gozlem (test yazarken netlesti): **kayit sinirinda biten** bir kuyruk
  yirtik sayilmaz. Cerceve tam, commit kaydi yoksa `TornTail=False`
  olur ve yalnizca beklemedeki kume atilir; `TornTail` yarim kayitta
  (basligin/yukun kesilmesi) uretilir. Bu davranis §3 W6 ile
  tutarlidir ve testte `t1b/clean-eof` olarak sabitlendi.

## 8. Sonuc

Sayfa WAL'in commit/fsync/kurtarma cekirdegi **kod ve test ile
dogrulanmis** durumda: torn tail, CRC bozulmasi, bozuk magic, gecersiz
uzunluk, commit'siz kuyruk, hayalet commit, idempotent kurtarma ve
guvenli budama kapsanir.

Buna karsin su maddeler **aciktir** ve "production-ready" denemez:
KV WAL at-rest sifreleme yoklugu (§6.1), sinirsiz KV WAL buyumesi
(§6.2), cift uygulama riski (§6.3), gercek ENOSPC testinin yoklugu
(§6.4), LSN wraparound (§6.5), es zamanli writer/checkpoint/backup
testinin yoklugu (§6.6) ve yedek/replikasyon crash noktalari (§6.7).

Bu maddeler sonraki fazlarin (p2-server-harden, p3-ci) girdisidir.
