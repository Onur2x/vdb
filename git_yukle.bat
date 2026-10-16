@echo off
setlocal
chcp 65001 >nul 2>&1
title VDB - Git tek tikla yukleme / one-click push
cd /d "%~dp0"

echo.
echo  ==============================================
echo    VDB  -  Git tek tikla yukleme / one-click
echo  ==============================================
echo.

echo  [1/5] Durum / Status:
echo  ----------------------------------------------
git status -sb
echo  ----------------------------------------------
echo.

echo  [2/5] Tum degisiklikleri ekle / Stage all:
git add -A
echo.

echo  [3/5] Commit:
set "MSG="
set /p "MSG=  Commit mesaji (Enter = otomatik): "
if "%MSG%"=="" set "MSG=Update / Guncelleme %DATE% %TIME%"
git commit -m "%MSG%"
if errorlevel 1 echo   (degisiklik yok / nothing to commit - devam)
echo.

echo  [4/5] Uzakla esitle (rebase) / Sync with remote:
git pull --rebase origin main
if errorlevel 1 (
  echo.
  echo  [HATA] Pull/rebase basarisiz - muhtemelen CAKISMA var.
  echo  Cakismayi coz:  git status   - ilgili dosyalari ac, <<<<<<< isaretlerini sil
  echo  Sonra:          git add DEGISTIRILEN && git rebase --continue
  echo  Vazgec:         git rebase --abort
  pause
  exit /b 1
)
echo.

echo  [5/5] Yukle / Push:
git push
if errorlevel 1 (
  echo.
  echo  [HATA] Push basarisiz - mesaji yukarida oku.
  pause
  exit /b 1
)

echo.
echo  ==============================================
echo    TAMAM / DONE  -  GitHub'a yuklendi.
echo  ==============================================
echo.
echo  vdbapi.dll'i Releases olarak yuklemek icin
echo  GIT_REHBERI.md bolumune bak.
echo.
pause