@echo off
REM VDb Manager (HAD) - Calistirma Scripti
REM Bu script derlenmis programi calistirir.

echo ========================================
echo VDb Manager (HAD) - Calistiriliyor
echo ========================================
echo.

REM Proje dizini
set PROJE_DIR=%~dp0
cd /d "%PROJE_DIR%"

echo Proje dizini: %PROJE_DIR%
echo.

if exist had.exe (
    echo Program calistiriliyor...
    echo.
    had.exe
) else (
    echo HATA: had.exe bulunamadi!
    echo Once 'build.bat' ile derleyin.
    echo.
    pause
    exit /b 1
)

echo.
echo Program kapanmistir.
pause