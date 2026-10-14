@echo off
echo Building VDB Web API (FPC Native)...

REM Derle
lazbuild main.pas

if errorlevel 1 (
    echo Build failed!
    pause
    exit /b 1
)

echo.
echo Build successful!
echo Run: main.exe
pause