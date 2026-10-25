# v2 → v3 göç aracı (`vdbmig`)

v2 veritabanını (satır-kayıt dosyası, imza `VODB`) v3 sayfa motoru dosyasına
(imza `VDB3`) taşıyan komut satırı aracı. Kopyalama ve doğrulamanın tamamı
motorda hazır olan `VDbMigrate.pas` ile yapılır; `vdbmig` yalnızca güvenlik
kontrollerini, raporu ve çıkış kodlarını ekler.

## Neden ayrı bir araç

- **Veri kaybı olmadan**: kaynak dosya **salt-okunur** açılır, hiç yazılmaz.
  Hedef yalnızca yoksa oluşturulur; var olan dosyanın üzerine **asla**
  yazılmaz.
- **Bayt bayt doğrulama**: kopya bittikten sonra her kaynak anahtar hedefte
  aranır ve değeri **bayt bayt** karşılaştırılır. Sayı eşitliği tek başına
  yeterli sayılmaz.
- **Sessiz bozuk dosya bırakmaz**: kopya yarıda kalırsa hedef silinir;
  doğrulama tutmazsa hedef `.bad` sonekiyle **karantinaya** alınır, böylece
  bir sonraki açılış onu geçerli veritabanı sanmaz.

## Uygulamalar neden v2 dosyasını açmıyor

`VDbFactory` (uygulama giriş noktası) **v3 varsayılandır**: `VdbOpen` /
`VdbOpenOrCreate` var olan bir v2 dosyasını `EVdbFactory` ile reddeder ve
şunu önerir:

```text
vdbmig copy "<v2_dizin>" "<yeni>.odb"
```

Yönetim GUI'si de aynı politikayı uygular (açılışta sessiz, kullanıcı dosya
seçtiğinde mesajlı). v2 yalnızca `AllowV2=True` ile açılır; bu yol göç
araçları içindir. Kaynak dosyaya hiçbir durumda yazılmaz.

## Derleme

```bash
lazbuild -B vdbmig.lpi
```

## Kullanım

```text
vdbmig copy   <kaynak> <hedef.odb> [--pool N] [--dry-run] [--quiet]
vdbmig verify <kaynak> <hedef.odb> [--pool N] [--quiet]
```

`<kaynak>` bir v2 **dizini** (içinde `veritabani.odb` olan) ya da doğrudan
`.odb` dosyası olabilir.

```
vdbmig copy D:\veritabani\db D:\veritabani\db\v3.odb
vdbmig copy D:\veritabani\db\veritabani.odb v3.odb --pool 512
vdbmig copy D:\veritabani\db v3.odb --dry-run
vdbmig verify D:\veritabani\db v3.odb
```

`--dry-run` yalnızca planı yazar (kaynağı açar, kayıt sayısını basar, hedefe
**dokunmaz**). `--quiet` yalnızca özet satırlarını gösterir.

### Çıkış kodları

| Kod | Anlamı |
|---:|---|
| 0 | tamam |
| 1 | kullanım hatası |
| 2 | hedef dolu (üzerine yazılmadı) |
| 3 | kaynak hatası (yok / bozuk / zaten v3) |
| 4 | kopya hatası (hedefte yarım dosya bırakılmadı) |
| 5 | doğrulama hatası (hedef `.bad` olarak karantinada) |

## Doğrulanmış ölçümler

Windows, FPC 3.2.4 i386-win32, tek koşu (`vdbmig`, varsayılan havuz 256):

| Kaynak | Kayıt | v2 dosya | v3 dosya | Kopya | Doğrulama |
|---|---:|---:|---:|---:|---:|
| `db\veritabani.odb` | 5.031 | 388.880 B | 327.680 B (%84,3) | 31 ms | <1 ms |
| `tmp64\goc200k\mig_src` | 200.001 | 16.201.267 B | 13.852.672 B (%85,5) | 547 ms | 219 ms |

Aynı 200k göçü `migchk` kapısı içinde: 531 ms kopya, 203 ms doğrulama
(`migchk 13/13`, `kalan=0`). Sayılar arasındaki fark normal koşu gürültüsüdür.

**Uçtan uca kontrol:** araçla üretilen 200k dosyası, v3 motoru + SQL katmanı
(`TVdbBackendV3` → `TVTableDb` → `TVSql`) ile ayrıca açıldı:

| Sorgu | Sonuç |
|---|---|
| `be.Count` | 200001 |
| `SELECT COUNT(*) FROM t` | 200000 |
| `SELECT SUM(s) FROM t` | 900000 |
| `SELECT v FROM t WHERE id = 100000` | `val-100000` |
| `SELECT COUNT(*) FROM t WHERE s = 7` | 20000 |

## Sınırlar (dürüst liste)

- **Şifreli / kolon anahtarlı v2 veritabanları** bu sürümde desteklenmez;
  parola/anahtar aktarımı yoktur (`.colkey` dosyası varsa hedefe kopyalanır,
  ama kaynak parola ile açılamıyorsa araç kaynağı açamaz).
- **Açık v2 oturumu** olan canlı bir dizin üzerinde çalıştırmayın: kaynak
  tutarlı bir an olarak okunur, yarım işlem görmez.
- Göç **tek yönlüdür** (v2 → v3). Geri dönüş gerekmiyorsa v2 dosyasını
  silmeyin; araç onu hiç değiştirmez, yani elinizde tam bir yedek kalır.
- Göç edilen v3 dosyasını **yönetim uygulaması (`yonetim/had`) henüz
  açamıyor**: GUI hâlâ yalnızca `VODB` imzasını tanıyor. v3 okuma desteği
  ayrı iştir.
- `.odb.idx` hedefte yeniden üretilir (türetilmiş dosya); kopyalanmaz.

## Doğrulama kapıları

- `migchk` (13/13): kopya + bayt bayt doğrulama, var olan hedef reddi, v3
  kaynaktan göç reddi, SQL yolu (`MIGRATE TO v3` / `MIGRATE VERIFY`), göç
  sonrası `COUNT`/`SUM`/PK/indeksli arama/ilk-son satır.
- `vdbmig` (CI adımı): gerçek bir v2 dosyası üzerinde `copy` → 0, aynı hedefe
  ikinci `copy` → 2, `verify` → 0.
