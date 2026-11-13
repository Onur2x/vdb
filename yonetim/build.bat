@echo off
REM VDb Manager (HAD) - Derleme Scripti
REM Bu script lazbuild kullanarak projeyi derler.

echo ========================================
echo VDb Manager (HAD) - Derleme Baslatiliyor
echo ========================================
echo.

REM Proje dizini
set PROJE_DIR=%~dp0
cd /d "%PROJE_DIR%"

echo Proje dizini: %PROJE_DIR%
echo.

REM Derleme
echo [1/2] Projeyi derleme...
lazbuild -B had.lpi

if errorlevel 1 (
    echo.
    echo HATA: Derleme basarisiz!
    echo.
    pause
    exit /b 1
)

echo.
echo [2/2] Derleme tamamlandi!
echo.

if exist had.exe (
    echo Program basariyla derlendi: had.exe
    echo.
    echo Programi calistirmak icin: had.exe
) else (
    echo UYARI: had.exe bulunamadi
)

echo.
echo ========================================
echo Derleme Basarili!
echo ========================================
pause