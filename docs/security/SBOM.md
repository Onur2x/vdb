# SBOM ve tedarik zinciri

Bu belge, "saf native, harici DLL yok" sozlesmesinin **denetlenebilir**
envanterini verir: neyin dahil oldugunu, neyin istege bagli oldugunu ve
neden hicbir seyin imzalanmadigini acikca yazar.

Makine okunabilir SBOM: [`vdb.cdx.json`](vdb.cdx.json) (CycloneDX 1.5,
elle tutulan, kucuk ve okunabilir envanter).
Lisans/atribusyon metinleri: [`../../NOTICE`](../../NOTICE).

## 1. Bilesen envanteri

| Bilesen | Surum | Lisans | Tur | Varsayilan olarak dahil? | Nerede yuklenir |
|---|---|---|---|---|---|
| VDB cekirdegi | 1.2 (`VDB_API_VERSION=$00010200`) | Public domain | kaynak | **evet** | 68 `.pas` (kok dizin) |
| Free Pascal RTL/FCL | 3.2.x | LGPL-2.1+ (FPC linking exception) | derleme/link | **evet** | `SysUtils, Classes, Generics.Collections, DateUtils, SyncObjs, dynlibs, BaseUnix, Windows, fpjson, jsonparser, DB` |
| Lazarus LCL | 4.6.x | LGPL-2.0+ (LCL exception) | derleme | hayir (yalniz `VDbDataSet`) | `VDbDataSet.pas` / IDE projeleri |
| OpenSSL `libcrypto` | 3.x, 1.1.x | Apache-2.0 / OpenSSL | calisma zamani, dinamik | **hayir** | `VDbCryptoOpenSSL.pas` (`dynlibs`) |
| OpenSSL `libssl` + `libcrypto` | 3.x, 1.1.x | Apache-2.0 / OpenSSL | calisma zamani, dinamik | **hayir** | `VDbTls.pas` (`dynlibs`) |
| DCPcrypt 2.0 | 2.0 | MIT | **kaldirildi** | **hayir** | Kaynak depoda yok; yalniz algoritma referansi |
| Kullanici eklentisi | — | cagirana ait | calisma zamani | **hayir** | `VDbExtension.pas` (yalniz cagiran yuklerse) |

### Dogrulama komutlari

```bash
# Depodaki unit sayisi (kok dizin)
ls *.pas | wc -l

# Dis bagimlilik arayan kontrol: LCL/OS-entegrasyon unit'leri `uses` ediliyor mu?
# (Bos donmesi beklenir. VDbText'teki `Forms := ...` bir yerel degiskendir,
#  bu kalip yalniz `Forms,` / `Forms;` seklindeki gercek import'lari yakalar.)
grep -nE '^[[:space:]]*(LCLIntf|Interfaces|Forms|Controls|zstream|process|pipes|sqlite3conn|LResources|LCLType)[[:space:]]*[,;]' *.pas

# Dinamik yukleme noktalari (hepsi istege bagli)
grep -n 'LoadLibrary\|dynlibs' *.pas
```

Beklenen sonuc: yukaridaki `uses` aramasi **bos** doner; `LoadLibrary`
yalniz `VDbCryptoOpenSSL`, `VDbTls`, `VDbPlatform`, `VDbExtension` ve
istege bagli `VDbClient` (vdbapi.dll istemcisi) icinde gorulur.

## 2. "Harici DLL yok" iddiasi ve siniri

Motor + `vdbapi` (statik kutuphane/DLL ihracati) icin **hicbir** harici
DLL gerekmez: kripto, KDF, TLS-disi her sey saf Pascal'dir. Isletim
sisteminin kendi kutuphaneleri (libc/ntdll) linker tarafindan baglanir;
bunlar uygulama bagimliligi sayilmaz.

Iki opsiyonel yuzey vardir ve ikisi de **acikca secilmedikce yuklenmez**:

1. **Kripto provider = OpenSSL.** Varsayilan `builtin`. OpenSSL istenirse
   `libcrypto` aranir; bulunamazsa **hata** verilir (sessiz fallback yok).
2. **TLS.** `VDbTls` yalniz TLS acikca etkinlestirildiginde `libssl` +
   `libcrypto` yukler.

Bu iki yol, `VDbExtension` ile yuklenen kullanici eklentileri gibi,
**tedarik zinciri yuzeyidir**; `THREAT_MODEL.md` R-08 olarak kayitlidir.

## 3. Bilinen zafiyet taramasi (durum)

| Kalem | Durum |
|---|---|
| Depoda paket yoneticisi manifesti (`package.json`, `*.csproj`, `requirements.txt`, `Cargo.toml`) | **Yok** — taranacak bagimlilik grafigi yok. |
| `npm audit` / `pip-audit` / `cargo audit` esdegeri | Uygulanamaz (harici paket yok). |
| OpenSSL surum takibi | Kullanici sorumlulugunda: VDB sistemdeki kopyayi yukler. Surum `VdbCryptoProvider` raporunda gorunur. |
| FPC/LCL surum takibi | Derleme zamaninda FPC surumu ile sabitlenir (`3.2.4` Windows / `3.2.2` WSL). CI iki platformda kosar. |

Dolayisiyla "SBOM taramasi gecti" gibi bir iddia **yoktur**; iddia sudur:
taranacak ucuncu taraf paket grafigi bulunmuyor ve opsiyonel iki yuzey
(OpenSSL, eklenti) acikca isaretli.

## 4. Imzalama / provenance karari

**Karar: bu surumde yayinlanan ikili (binary) artefakt yok, dolayisiyla
imzalanacak bir sey de yok.**

Gerekce ve simdiki gercek:

- Depoda `vdbapi.dll`, `vdbcli.exe`, `vdbmig.exe`, `vdbserver.exe` gibi
  derlenmis dosyalar **yerelde** bulunur ama surum artefakti olarak
  yayinlanmaz; `.gitignore` kapsamindadir.
- GitHub Releases uzerinden dagitilan imzali bir surum **yok**.
- CI yalniz kapi kosar; artefakt yayinlamaz.

Yayin artefakti uretilmeye baslandiginda izlenecek yol (karar kaydi):

1. Her surum icin `vdb.cdx.json` yeniden uretilir ve surumle birlikte
   yayinlanir (SBOM artefakta eslik eder).
2. Ikililer **GitHub Actions OIDC + Sigstore/cosign** ile anahtarsiz
   (keyless) imzalanir; provenance `slsa-framework/slsa-github-generator`
   ile uretilir. Uzun omurlu imza anahtari tutulmaz.
3. `SHA256SUMS` + imza dosyasi ayni release'e eklenir; README indirme
   bolumunde dogrulama komutu yayinlanir.

Bu uc adim **henuz uygulanmadi**; yayin akisi olmadigi icin uydurma bir
imza adimi eklemek yaniltici olurdu.

## 5. Guncelleme kurali

Yeni bir dis bagimlilik (DLL, unit, paket, eklenti ABI'si) eklenirse ayni
commit'te:

- `vdb.cdx.json`'a bilesen satiri,
- bu belgedeki tabloya satir,
- gerekiyorsa `NOTICE`'a lisans metni

eklenir. `THREAT_MODEL.md` R-08'in durumu buna gore guncellenir.
