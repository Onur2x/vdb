# VDB V3 - Crash Recovery Stress Raporu

Tarih: 2026-11-24
Kapsam: 100 zorla sonlandirma (crash) dongusu
Platform: Windows (i386-win32, fpc 3.2.4)

## Amac

Her dongude bir yazar surec, bilincli bir asama noktasinda (crash point)
surec sonlandirilir; ardindan dosya yeniden acilir, WAL kurtarmasi calisir
ve sonuc dogrulanir. Amac, "commit edildi" diye donen hicbir yazinin
kurtarma sonrasinda kaybolmadigini gostermektir.

## Yontem

- Arac: `tests/crash_stress/crash_stress.lpr` (saf native, harici DLL yok).
- API: basit KV yolu (`BeginBatch` / `Put` / `CommitBatch` / `Count` / `Verify`).
  SQL katmani bu testte kullanilmaz; amac depolama katmanidir.
- Dongu basina 30 anahtar yazilir; her dongude crash asamasi degisir:
  - `uncommitted`  (60 dongu): commit edilmeden once sonlandir.
  - `postcommit`   (20 dongu): commit dondukten hemen sonra sonlandir.
  - `checkpoint`   (20 dongu): checkpoint sirasinda sonlandir.
- Surec cikis kodu 9 ile oldurulur (kontrollu sonlandirma).
- Her donguden sonra: dosya acilir, `Count` ve `Verify` calistirilir,
  yazilabilirlik (yeniden yazma) denenir.

## Sonuclar

Kaynak log: `build/c100.log`.

```
SONUC: 101 PASS, 0 FAIL
CS SONUC: tum donguler temiz - 100 dongu
```

Her dongunun satiri ayni bicimdedir:

```
PASS C100 uncommitted - rc=9 count=30 beklenen=30 verify=yes yazilabilir=yes
```

Yani 100 dongunun tamaminda:

- kurtarma sonrasi anahtar sayisi beklenen degerle ayni (30/30),
- `Verify` temiz (sayfa/freelist/anahtar tutarli),
- dosya yeniden yazilabilir durumda (kalici kilit sizintisi yok).

## Sinirlar (durust not)

- Bu test surec-sonlandirma senaryosunu kapsar; isletim sistemi cokmesi,
  guc kesintisi ve disk denetim hatasi (bit rot) kapsam DISIDIR.
  Bunlar icin `build/c100.log` bir kanit degildir.
- 100 dongu, 30 anahtar/dongu olcegindedir. Cok daha buyuk veri hacminde
  kurtarma suresi olculmemistir.
- Test Windows uzerinde kosulmustur; Linux kosumu bu rapor icin
  tekrarlanmamistir.

## Tekrar uretme

```
build\bcrash.cmd
build\tcrash\crash_stress.exe 100
```
