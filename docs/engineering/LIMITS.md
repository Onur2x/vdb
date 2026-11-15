# VDB V3 - Isletim Sinirlari ve Kaynak Yonetimi

Bu belge SKILL2 §25 ve SKILL3 §12'nin istedigi **acik sinirlari** listeler.
Kural: her sinir asildiginda motor **kontrollu** `EVDbException` dondurur
(`ecLimit` / `ecIOError` / `ecCorrupt`), surec cokmez ve veritabani dosyasi
gecerli kalir. Sinir denemelerinden sonra ayni veritabani normal calismaya
devam eder; bunu `tests/limits` kapisi olcer (18 kontrol).

| Sinir | Deger | Nerede zorlanir | Hata |
|---|---|---|---|
| Sayfa boyu | 4096 B (sabit) | `VDbPage.pas` `VDB_PAGE_SIZE` | - |
| Sayfa sayisi | 16 777 215 (`$00FFFFFF`) | `VDbPageStore.ExtendFile` | `ecLimit` |
| Veritabani boyu | 1 TiB | `VDbPageStore.ExtendFile` + `GrowTo` | `ecLimit` |
| Tek islemde degisen sayfa | 1 048 576 | `VDbPageStore.MarkPageDirty` | `ecLimit` |
| WAL boyu | turetilmis: 8 MB esik + 4 GiB (islem tavani x 4096) | `MaybeCheckpoint` (8 MB'de checkpoint) + islem tavani | - |
| Tek SQL cumlesi | 4 MiB | `VDbSql.CheckStmtSize` (`Exec`, parametreli `Exec`, `ExecRaw`) | `ecLimit` |
| Tek deger | 16 MiB | `VDbTypes.VDB_MAX_VALUE` (API `Put` yolu) | `ecLimit` |
| Sonuc satiri | 2 000 000 | `VDbExecutor` cikti buyume yollari + LIMIT/JOIN/DISTINCT | `ecLimit` |
| Onbellek (sayfa havuzu) | varsayilan 512, tavan 65 536 (=256 MB) | `VDbPageStore` clamp | sessiz clamp |
| Baglanti (sunucu) | varsayilan 64, ayar araligi 1..4096 | `VDbSqlServer`, `VDbPgWire` | baglanti reddi |
| Indeks derinligi | skiplist 62 seviye; B+Tree dengeli | `VDbSkipList` | - |
| Es zamanli islem | baglanti tavaniyla sinirli; tek dosyada yazma kilidi islem basina | `VDbPageStore` kilit modeli | kilit hatasi |

## Bilincli olarak SINIR KOYULMAYAN yerler

- **Onbellek tavani sessiz clamp**: `APoolPages > VDB_MAX_POOL` istegi
  kirpilir, hata verilmez. Bu bir bellek guvenligi siniri; istek reddi
  yerine kucuk havuzla devam etmek daha az surpriz uretir.
- **WAL sert tavani yok**: 8 MB'de checkpoint tetiklenir; acik islem ya da
  kilit nedeniyle checkpoint ertelenirse WAL buyumeye devam eder. Ust sinir
  islem tavaniyla turetilir (en kotu durum ~4 GiB). Bu davranis bilinclidir:
  sert bir WAL tavani, mesru uzun islemleri commit aninda reddederdi.
- **Islem sayisi tavani yok**: es zamanli islem sayisi baglanti tavaniyla
  ve tek dosyada yazma kilidiyle sinirlidir.

## Kapanis (SKILL2 §25.3)

`TVdbPageEngine.Close` sirasi:

1. Yeni is kabul edilmez (nesne kapaniyor).
2. Acik islem varsa commit edilmemis sayfalar atilir (WAL'de onay yok).
3. Checkpoint calisir; basarisizsa yan dosyalara **dokunulmaz**.
4. Checkpoint basariliysa ve ayni surecte ayni dosyaya acik **baska oturum
   yoksa** `.wal`/`.gen` silinir (tek dosya sozlesmesi).
5. Dosya kilidi ve tutamaklar birakilir.

Kapanis hatalari yutulmaz: checkpoint sonucu `False` ise yan dosyalar
korunur, yani veri kaybi yerine "fazladan dosya" tercih edilir. Bu yolu
`tests/single_file`, `tests/multi_writer` (MW2/MW4) ve `tests/crash_points`
olcer. **Sunucu kapanisi** (`VDbSqlServer.Stop`) ayri bir kapiyla
olculmuyor; bu belgede sinir olarak kayitli.
