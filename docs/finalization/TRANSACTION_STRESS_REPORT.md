# VDB V3 - Transaction Stress Raporu

Tarih: 2026-11-24
Kapsam: 1000 islem (transaction) dongusu
Platform: Windows (i386-win32, fpc 3.2.4)

## Amac

Uzun sureli karisik islem yuku altinda su ozellikleri dogrulamak:
atomiklik, izolasyon, birincil anahtar (PK) ihlali davranisi, ifade hatasi
sonrasi geri alma, cift/kismi satir olusmamasi ve commit/rollback gecikmesi.

## Yontem

- Arac: `tests/tx_stress/tx_stress.lpr` (saf native).
- 1000 dongu; her dongude karisik islem kalibi kosulur:
  commit, rollback, PK ihlali, ifade hatasi, cakisma denemesi.
- Her 50 dongude tam `VERIFY` calistirilir; sonda dosya kapatilip
  yeniden acilarak kalicilik kontrol edilir (Z1..Z6).
- Sureler `GetTickCount` tabanli olculur (mikrosaniye).

## Sonuclar

Kaynak log: `build/tx1000.log`.

```
SONUC: 34 PASS, 0 FAIL
PASS Z2 satir sayisi korundu - 999/999
PASS Z3 kontrol toplami korundu - 28076/28076
PASS Z4 cift/kismi satir yok - distinct=999 satir=999
PASS Z5 VERIFY temiz - sayfa=10 serbest=0 heap=9 tasma=0 trunk=0 anahtar=1000 lsn=835
PASS Z6 SONUC: tum tx donguleri temiz - 1000 dongu
```

Gecikme olcumleri (mikrosaniye):

```
commit   n=333  p50=1275  p95=1855  max=3434  ort_ilk50=1102  ort_son500=1194
rollback n=501  p50=187   p95=275   max=402   ort_ilk50=198   ort_son500=194
```

Hata yollari:

```
pk_ihlali_tetik=167  ifade_hatasi_tetik=167
cakisma_kabul=0      cakisma_red=166     izolasyon_ihlali=0
```

Yani 167 PK ihlali denemesi tetiklendi ve test bunlarin reddedildigini
dogruladi (34 PASS / 0 FAIL); 167 ifade hatasi temiz geri alindi,
166 cakisma reddedildi ve hicbir cakisma kabul edilmedi (kayip guncelleme
yok).

## Notlar (durust sinirlar)

- Olcumler tek makine, tek disk, soguk olmayan onbellek kosullarindadir;
  baska donanimda farkli cikar. Karsilastirmali bir benchmark degildir.
- `commit` gecikmesi `DurableOnFlush` varsayilan ayariyla olculmustur;
  fsync maliyeti disk ve isletim sistemi ayarlarina baglidir.
- Es zamanli coklu surec yuku bu raporda ayrica olculmemistir
  (bkz. `multi_writer` kapisi ayri kosar).

## Tekrar uretme

```
build\btx.cmd
build\ttx\tx_stress.exe 1000
```
