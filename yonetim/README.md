# VDb Studio — Veritabanı Yönetim Programı / Database Management Tool

> **TR:** VDb Studio, VDB veritabanı motoru için masaüstü yönetim programıdır. phpMyAdmin tarzı arayüz ile veritabanı yönetimi, SQL çalıştırma, veri görüntüleme/düzenleme ve bakım işlemleri yapar.
>
> **EN:** VDb Studio is a desktop management tool for VDB database engine. phpMyAdmin-style interface for database management, SQL execution, data viewing/editing, and maintenance.

---

## 📌 Özellikler / Features

### TR
- ✅ Veritabanı oluşturma, açma, silme
- ✅ Tablo yapısı görüntüleme ve düzenleme
- ✅ Veri görüntüleme, ekleme, silme, düzenleme
- ✅ İndeks yönetimi
- ✅ İlişki (FK) görüntüleme
- ✅ SQL çalıştırma + geçmiş
- ✅ Şema görüntüleme (DESCRIBE, SHOW INDEXES)
- ✅ Yedekleme, doğrulama, sıkıştırma
- ✅ WAL yönetimi
- ✅ İçe/dışa aktarma (CSV, JSON)
- ✅ Karanlık/aydınlık tema
- ✅ **Çok dilli: Türkçe / İngilizce** 🆕

### EN
- ✅ Create, open, delete databases
- ✅ View and edit table structure
- ✅ View, insert, delete, edit data
- ✅ Index management
- ✅ Relationship (FK) viewing
- ✅ SQL execution + history
- ✅ Schema viewing (DESCRIBE, SHOW INDEXES)
- ✅ Backup, verify, compact
- ✅ WAL management
- ✅ Import/export (CSV, JSON)
- ✅ Dark/light theme
- ✅ **Multi-language: Turkish / English** 🆕

---

## 🌐 Çok Dilli Destek / Multi-Language Support

### TR
VDb Studio artık Türkçe ve İngilizce dillerini destekliyor. Dil değiştirmek için:

1. **Menü → Görünüm → Dil** (View → Language)
2. **Türkçe** veya **English** seçin

Dil değişimi anında uygulanır. Tüm menüler, düğmeler, sekmeler ve mesajlar seçilen dilde görüntülenir.

### EN
VDb Studio now supports Turkish and English. To change language:

1. **Menu → View → Language**
2. Select **Türkçe** or **English**

Language change is applied instantly. All menus, buttons, tabs, and messages are displayed in the selected language.

### Teknik Detaylar / Technical Details
- `uLang.pas` birimi dil çevirilerini yönetir / `uLang.pas` unit manages translations
- `CurrentLang` global değişkeni seçilen dili tutar / `CurrentLang` global variable stores selected language
- `L(TR, EN)` fonksiyonu iki dilli metin döndürür / `L(TR, EN)` function returns bilingual text

---

## 🛠️ Derleme / Build

### TR
```bash
# Lazarus ile / With Lazarus
lazbuild -B yonetim/had.lpi

# veya komut satırı / or command line
cd yonetim
lazbuild -B had.lpi

# Çalıştır / Run
had.exe
```

### EN
Same build commands.

---

## 📁 Dosyalar / Files

### TR
| Dosya | Açıklama |
|---|---|
| `had.lpr` | Ana program / Main program |
| `hadmain.pas` | Ana form (arayüz) / Main form (UI) |
| `haddlg.pas` | Diyaloglar / Dialogs |
| `hadtools.pas` | Yardımcı fonksiyonlar / Utility functions |
| `uLang.pas` | **Çok dilli destek** / Multi-language support 🆕 |
| `README.md` | Bu dosya / This file |

### EN
Same files as above.

---

## 🎨 Tema / Theme

### TR
VDb Studio iki tema destekler:
- **Aydınlık** (varsayılan) / Light (default)
- **Karanlık** / Dark

Tema değiştirmek için: **Menü → Görünüm → Tema**

### EN
VDb Studio supports two themes:
- **Light** (default)
- **Dark**

Change theme: **Menu → View → Theme**

---

## 📊 Sekmeler / Tabs

### TR
1. **Veritabanı** — Genel bilgiler, yedekleme, bakım
2. **Yapı** — Tablo yapısı, kolonlar, kısıtlar
3. **Veri** — Satır görüntüleme, düzenleme, filtreleme
4. **İndeksler** — İndeks listesi, oluşturma, silme
5. **İlişkiler** — FK ilişkileri
6. **Şema** — DESCRIBE, SHOW INDEXES, SHOW CREATE TABLE
7. **SQL** — SQL çalıştırma, geçmiş, şablonlar
8. **Bul** — Veri arama
9. **Araçlar** — İçe/dışa aktarma, WAL, bakım

### EN
Same tabs as above.

---

## 🔧 Gereksinimler / Requirements

### TR
- Lazarus 4.6+ (LCL gerekli)
- VDB motor birimleri (ana dizinde)
- Windows, Linux veya macOS

### EN
- Lazarus 4.6+ (LCL required)
- VDB engine units (in main directory)
- Windows, Linux, or macOS

---

## 📸 Ekran Görüntüleri / Screenshots

### TR
*Yakında eklenecek / Coming soon*

### EN
*Coming soon*

---

## 📝 Değişiklikler / Changes

### TR
- **2026-10-14:** Çok dilli destek eklendi (Türkçe/İngilizce)
- **2026-10-13:** Arayüz iyileştirmeleri
- **2026-10-12:** İlk sürüm

### EN
- **2026-10-14:** Multi-language support added (Turkish/English)
- **2026-10-13:** UI improvements
- **2026-10-12:** Initial release

---

## 📞 Destek / Support

### TR
- `README.md` — Proje özeti
- `KILAVUZ_TR_EN.md` — Kullanım kılavuzu
- `SQL_TR_EN.md` — SQL referansı

### EN
Same support documents.

---

**Son güncelleme / Last updated:** 2026-10-14
**Diller / Languages:** Türkçe (TR), English (EN)