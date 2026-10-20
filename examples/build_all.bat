@echo off
REM ============================================
REM VDB - Tek Tikla Derleme / One-Click Build
REM ============================================
REM TR: Tum ornekleri, testleri ve DLL'leri derler
REM EN: Compiles all examples, tests and DLLs
REM
REM TR: Tek komutla her seyi derler; test paketinin
REM     %100 calismasi icin gerekli her dosyayi uretir.
REM EN: Builds everything in one command; produces every
REM     file needed for the test suite to run 100%.
REM
REM Kullanim / Usage:
REM   derle_tumu.bat
REM ============================================

setlocal enabledelayedexpansion

echo ============================================
echo   VDB DERLEME / VDB BUILD
echo   Tum ornekler, testler ve DLL'ler
echo   All examples, tests and DLLs
echo ============================================
echo.

REM TR: FPC yolu / FPC path
set FPC=C:\lazarus\fpc\3.2.4\bin\i386-win32\fpc.exe
set LAZBUILD=C:\lazarus\lazbuild.exe

REM TR: Birim yollari (ornekler icin) / Unit paths (for examples)
set UNITS=-Fu.. -Fu..\..\ -Fu..\..\dcpcrypt -Fu..\..\dcpcrypt\Ciphers -Fu..\..\dcpcrypt\Hashes

REM TR: Basari sayaci / Success counter
set PASS=0
set FAIL=0
set TOTAL=14

call :build_example "1" "Ornek 01 - Basit Kullanim / Basic Usage" "01_basit_kullanim" "ornek01"
call :build_example "2" "Ornek 02 - SQL Sorgulari / SQL Queries" "02_sql_sorgulari" "ornek02"
call :build_example "3" "Ornek 03 - CRUD Islemleri / CRUD Operations" "03_crud_islemleri" "ornek03"
call :build_example "4" "Ornek 04 - Transaction" "04_transaction" "ornek04"
call :build_example "5" "Ornek 05 - JOIN Islemleri / JOIN Operations" "05_join_islemleri" "ornek05"
call :build_example "6" "Ornek 06 - Sifreleme / Encryption" "06_sifreleme" "ornek06"
call :build_example "7" "Ornek 07 - TCP Sunucu / TCP Server" "07_tcp_sunucu" "ornek07"
call :build_example "8" "Ornek 08 - TCP Istemci / TCP Client" "08_tcp_istemci" "ornek08"
call :build_example "9" "Ornek 09 - JSON" "09_json_veri" "ornek09"
call :build_example "10" "Ornek 10 - Ileri Ozellikler / Advanced Features" "10_ileri_ozellikler" "ornek10"

echo [11/%TOTAL%] Ornek 11 - GUI (DBGrid)...
cd /d "%~dp0examples\11_gui_ornek"
del *.o *.ppu 2>nul
%LAZBUILD% -B ornek11.lpi > compile.log 2>&1
if exist ornek11.exe (
    echo        OK / Success
    set /a PASS+=1
) else (
    echo        FAIL / Error - compile.log dosyasina bakin
    set /a FAIL+=1
)

echo [12/%TOTAL%] Ornek 12 - 1M Kayitli GUI Demo / 1M-row GUI demo...
cd /d "%~dp0examples\12_milyon_demo"
del *.o *.ppu 2>nul
%LAZBUILD% -B ornek12.lpi > compile.log 2>&1
if exist ornek12.exe (
    echo        OK / Success
    set /a PASS+=1
) else (
    echo        FAIL / Error - compile.log dosyasina bakin
    set /a FAIL+=1
)

echo [13/%TOTAL%] Test Paketi / Test Suite (sqltest)...
cd /d "%~dp0"
del *.o *.ppu 2>nul
%LAZBUILD% -B sqltest.lpi > compile.log 2>&1
if exist sqltest.exe (
    echo        OK / Success
    set /a PASS+=1
) else (
    echo        FAIL / Error - compile.log dosyasina bakin
    set /a FAIL+=1
)

echo [14/%TOTAL%] DLL API (vdbapi)...
cd /d "%~dp0"
del *.o *.ppu 2>nul
%LAZBUILD% -B vdbapi.lpi > compile.log 2>&1
if exist vdbapi.dll (
    echo        OK / Success
    set /a PASS+=1
) else (
    echo        FAIL / Error - compile.log dosyasina bakin
    set /a FAIL+=1
)

echo.
echo ============================================
echo   DERLEME SONUCU / BUILD RESULT
echo ============================================
echo   Basarili / Success: %PASS%
echo   Basarisiz / Failed: %FAIL%
echo   Toplam / Total:     %TOTAL%
echo ============================================
echo.

if %FAIL%==0 (
    echo   TUMU BASARILI! / ALL SUCCESSFUL!
    echo.
    echo   TR: Simdi test paketini calistirabilirsiniz:
    echo       sqltest.exe
    echo   EN: You can now run the test suite:
    echo       sqltest.exe
) else (
    echo   BAZI HATALAR VAR! / SOME ERRORS!
    echo   Detaylar icin compile.log / compile_ext.log dosyalarina bakin.
    echo   See compile.log / compile_ext.log files for details.
)

echo.
echo Cikmak icin bir tusa basin / Press any key to exit...
pause > nul
goto :eof

REM --------------------------------------------
REM Alt yordam: bir ornek programi derler
REM Subroutine: compiles one example program
REM   %1 = adim no / step no
REM   %2 = baslik / title
REM   %3 = klasor / folder
REM   %4 = kaynak govdesi / source base name
REM --------------------------------------------
:build_example
echo [%~1/%TOTAL%] %~2...
cd /d "%~dp0examples\%~3"
del *.o *.ppu 2>nul
%FPC% %UNITS% %~4.lpr > compile.log 2>&1
if exist %~4.exe (
    echo        OK / Success
    set /a PASS+=1
) else (
    echo        FAIL / Error - compile.log dosyasina bakin
    set /a FAIL+=1
)
goto :eof