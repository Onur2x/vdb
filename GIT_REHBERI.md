# Git Kılavuzu / Git Guide

Bu dosya VDB deposunu GitHub'a yüklemek, güncellemek ve sürüm (release)
yayınlamak için günlük komutları içerir.

This file covers the everyday commands to push, update and publish a
release for the VDB repository.

---

## TR — Türkçe

### 0) Tek tıkla (en kolay)

Depo kökünde `git_yukle.bat` var. Değişikliklerini yaptıktan sonra çift
tıkla: ekler → commit eder → uzakla eşitler (`pull --rebase`) → yükler (`push`).
Mesajı sorar, boş geçersen otomatik tarihli mesaj kullanır.

### 1) Günlük akış (manuel)

```
git status                    # ne değişmiş gör
git add -A                    # tüm değişiklikleri ekle
git commit -m "Ne yaptım"     # kaydet
git pull --rebase origin main # uzaktakileri al, kendi işini üste koy
git push                      # GitHub'a yükle
```

> **Neden `pull --rebase`?** Uzakta (ör. GitHub web'den) senin yapmadığın
> commit'ler varsa `push` reddedilir. `pull --rebase` uzaktakileri alır,
> senin commit'lerini onların **üstüne** düzgünce koyar. Geçmiş düzgün
> (doğrusal) kalır.

### 2) Uzakla senkron (başkası/ sen başka yerden değişiklik yaptıysan)

```
git fetch origin                     # uzaktakileri getir (birleştirmez)
git log --oneline main..origin/main  # uzakta olup bende olmayanlar
git pull --rebase origin main        # birleştir
```

### 3) Çakışma (conflict) olursa

`git pull --rebase` bir dosyada çakışma çıkarırsa:

```
git status                 # <<<<<<< işaretli dosyaları gösterir
```

1. Çakışan dosyayı aç, `<<<<<<<` / `=======` / `>>>>>>>` işaretleri arasından
   **doğru sonucu** elle seç, işaretleri sil.
2. Devam et:

```
git add çözülen_dosya.pas
git rebase --continue
```

Vazgeçip başa dönmek istersen:

```
git rebase --abort
```

### 4) Yeni sürüm + `vdbapi.dll`'i Release asset olarak yükleme

1. Önce kodu yükle: `git push`
2. Tarayıcıda: **https://github.com/onur2x/VDB** → **Releases** → **Draft a new release**
3. **Tag:** `v2.0` (yeni etiket), hedef: `main`
4. Başlık + not (kopyala-yapıştır):

   > **VDB v2.0 — Database Engine**
   > - `vdbapi.dll` — C/API (stdcall, UTF-8): `VdbOpen/VdbPut/VdbGet/VdbExec` +
   >   SQL sonuçları, WAL, şifreleme, CDC. 32-bit Windows (i386).
   > - Kullanım: başlık **`vdbapi.h`** depoda (`/vdbapi.h`). Her dilden
   >   `LoadLibrary` + stdcall ile çağrılır.
   > - API sürümü: `VdbApiVersion` = `$00010000`

5. **"Attach binaries"** alanına `D:\veritabani\vdbapi.dll` dosyasını sürükle.
6. **Publish release.**

> İstersen `had.exe` (yonetim GUI) ve `ornek11.exe` (DBGrid örneği) dosyalarını
> da aynı release'e ekleyebilirsin.

### 5) Sık kullanılan komutlar

| Ne yapmak istiyorum | Komut |
|---|---|
| Durumu gör | `git status` |
| Geçmişi gör | `git log --oneline -10` |
| Değişiklikleri gör | `git diff` |
| Her şeyi ekle | `git add -A` |
| Kaydet | `git commit -m "mesaj"` |
| Uzakla eşitle | `git pull --rebase origin main` |
| Yükle | `git push` |
| Yeni sürüm etiketi | `git tag v2.0 && git push origin v2.0` |
| Bir dosyayı geri al | `git checkout -- dosya.pas` |
| Son commit'i düzelt | `git commit --amend` |

### 6) Bu repo için notlar

- **Remote:** `origin` → `https://github.com/onur2x/VDB.git`
- **Dal:** `main`
- **Yüklenmeyen dosyalar (`.gitignore`):** `*.exe`, `*.dll`, `*.o`, `*.ppu`,
  `*.log`, `*.odb`, `db/`, `yedek2/`, `mtakip/`, `webadmin/`, `ayar.txt`, `tema.txt`.
  Bunlar bilerek dışlanır; binary'ler **Releases**'tan paylaşılır, ağaca konmaz.
- **Derleme:** `derle_tumu.bat` (tek tıkla tüm örnekler + `vdbapi.dll` + testler).

---

## EN — English

### 0) One click (easiest)

`git_yukle.bat` sits in the repo root. After making your changes,
double-click it: it stages → commits → syncs (`pull --rebase`) → pushes.
It asks for a message; press Enter for an auto timestamped one.

### 1) Daily flow (manual)

```
git status                    # see what changed
git add -A                    # stage everything
git commit -m "What I did"    # save
git pull --rebase origin main # take remote work, put mine on top
git push                      # upload to GitHub
```

> **Why `pull --rebase`?** If the remote has commits you don't (e.g. made on
> the GitHub web UI), `push` is rejected. `pull --rebase` fetches them and
> replays your commits neatly **on top**, keeping history linear.

### 2) Sync with remote

```
git fetch origin
git log --oneline main..origin/main
git pull --rebase origin main
```

### 3) Resolving conflicts

If `git pull --rebase` reports a conflict:

```
git status
```

1. Open the conflicted file, pick the **correct result** between the
   `<<<<<<<` / `=======` / `>>>>>>>` markers, delete the markers.
2. Continue:

```
git add resolved_file.pas
git rebase --continue
```

To bail out and return to the original state:

```
git rebase --abort
```

### 4) New release + upload `vdbapi.dll` as an asset

1. Push the code first: `git push`
2. Browser: **https://github.com/onur2x/VDB** → **Releases** → **Draft a new release**
3. **Tag:** `v2.0`, target: `main`
4. Title + notes (copy/paste):

   > **VDB v2.0 — Database Engine**
   > - `vdbapi.dll` — C/API (stdcall, UTF-8): `VdbOpen/VdbPut/VdbGet/VdbExec` +
   >   SQL results, WAL, encryption, CDC. 32-bit Windows (i386).
   > - Usage: header **`vdbapi.h`** in the repo (`/vdbapi.h`). Callable from any
   >   language via `LoadLibrary` + stdcall.
   > - API version: `VdbApiVersion` = `$00010000`

5. Drag `D:\veritabani\vdbapi.dll` into **"Attach binaries"**.
6. **Publish release.**

> You can also attach `had.exe` (manager GUI) and `ornek11.exe` (DBGrid sample).

### 5) Common commands

| I want to | Command |
|---|---|
| See status | `git status` |
| See history | `git log --oneline -10` |
| See changes | `git diff` |
| Stage all | `git add -A` |
| Save | `git commit -m "message"` |
| Sync remote | `git pull --rebase origin main` |
| Upload | `git push` |
| Tag a release | `git tag v2.0 && git push origin v2.0` |
| Undo a file | `git checkout -- file.pas` |
| Amend last commit | `git commit --amend` |

### 6) Notes for this repo

- **Remote:** `origin` → `https://github.com/onur2x/VDB.git`
- **Branch:** `main`
- **Not uploaded (`.gitignore`):** `*.exe`, `*.dll`, `*.o`, `*.ppu`, `*.log`,
  `*.odb`, `db/`, `yedek2/`, `mtakip/`, `webadmin/`, `ayar.txt`, `tema.txt`.
  Intentionally excluded; binaries are shared via **Releases**, not the tree.
- **Build:** `derle_tumu.bat` (one click: all examples + `vdbapi.dll` + tests).