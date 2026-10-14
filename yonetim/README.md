# VDb Manager (HAD) - README

## Proje Açıklaması
VDb Manager (HAD), VDb (Veritabani) motorunun kapsamlı bir GUI yönetim arayüzüdür. phpMyAdmin benzeri özellikler sunar ve veritabanı yönetimini kolaylaştırır.

## Gereksinimler
- Lazarus IDE (https://www.lazarus-ide.org/)
- Free Pascal Compiler (FPC) 3.2.4 veya üzeri
- Windows platformu (i386-win32)

## Derleme ve Çalıştırma

1. Projeyi klonlayın veya indirin:
   ```
   git clone https://github.com/yourusername/had.git
   cd had
   ```

2. Derleme komutları:
   ```
   lazbuild -B had.lpi
   ```

3. Derlenmiş dosya:
   ```
   had.exe
   ```

4. Programı çalıştırma:
   ```
   had.exe
   ```

## Proje Yapısı

- `had.lpr` - Ana program dosyası
- `had.lpi` - Lazarus proje konfigürasyonu
- `hadmain.pas` - Ana form implementasyonu
- `haddlg.pas` - Yardımcı diyalog formları
- `hadtools.pas` - Utility fonksiyonlar
- `ayar.txt` - Program ayarları
- `tema.txt` - Tema ayarları

## Özellikler

- Veritabanı yönetimi (aç, oluştur, sil, yedekle, doğrula)
- Tablo yönetimi (ekle, sil, yeniden adlandır, sütun ekleme)
- Veri görüntüleme ve düzenleme
- SQL sorgu çalıştırma ve kaydetme
- CSV/JSON/SQL içe/dışa aktarma
- WAL (Write-Ahead Log) desteği
- Otomatik yedekleme
- Tema desteği (koyu/açık)
- Gelişmiş arama ve filtreleme
- İndeks yönetimi
- Transaksiyon desteği

## Lisans
Bu proje MIT Lisansı altında olup, kopyalanması, değiştirilmesi ve dağıtılması serbesttir.

## Katkı Sağlama
Katkılarınızı memnuniyetle kabul edelim. İsteğe bağlı olarak:
- Hatalar ve öneriler raporlayın
- Yeni özellikler ekleyin
- Belgelendirme iyileştirin
- Testler ekleyin

## Yardım ve Destek
Sorularınız veya sorunlar için lütfen Issues bölümünü kullanın veya direkt bize ulaşın.

---

*Bu proje, FPC (Free Pascal Compiler) ile geliştirilmiştir ve Windows platformu üzerinde çalışır.*