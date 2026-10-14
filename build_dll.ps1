# build_dll.ps1 - vdbapi.dll derler (Windows / i386-win32).
#
# R-23 Cross-Platform DLL / C API
# -------------------------------
# Motor saf FPC RTL'e indirgendi; LazUtils/FileUtil bagimliligi ARTIK
# YOKTUR. Bu yuzden `-Fu<lazutils>` satiri kaldirildi ve derleme yalnizca
# motor birimleri + dcpcrypt ile yapilir. Ayni kaynak (vdbapi.lpr)
# Linux/macOS'ta libvdbapi.so / libvdbapi.dylib uretir (bkz. build_lib.sh).
#
# Neden ayri bir betik? Lazarus'un .lpi XML'inde kutuphane turunun
# isareti (LibraryType) bu kurulumda okunmuyor ve projeyi .exe olarak
# bagliyor. Motor da her zaman FPC / i386-win32 ile derlendigi icin,
# FPC'yi dogrudan cagirmak hem daha hizli hem de Lazarus'un ekledigi
# ondalik bayraklardan etkilenmez.
#
# ONEMLI: -Mdelphi BILINCLI olarak VERILMEZ. VDbCrc32.pas icindeki bir
# yorumda `{$mode delphi}` dizisi geciyor; delphi modunda FPC yorumu
# `}` ile kapayip satirin kalanini kod sayiyor ve derleme kiriliyor.
# FPC'nin ontanilan modunda ic ice yorumlar serbest oldugu icin
# dosya dogru derleniyor (Lazarus da ayni modu kullanir).
#
# Kullanim:  powershell -ExecutionPolicy Bypass -File build_dll.ps1

$ErrorActionPreference = 'Stop'

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- FPC bul: $env:FPC > PATH > yaygin kurulum yerleri --------------
function Find-Fpc {
    if ($env:FPC -and (Test-Path $env:FPC)) { return $env:FPC }
    $onPath = Get-Command 'ppc386.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    foreach ($root in @('C:\lazarus\fpc', 'D:\lazarus\fpc',
                        'C:\FPC', 'D:\FPC')) {
        if (Test-Path $root) {
            $hit = Get-ChildItem -Path $root -Recurse -Filter 'ppc386.exe' `
                       -ErrorAction SilentlyContinue |
                   Sort-Object FullName -Descending | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

$fpc = Find-Fpc
if (-not $fpc) { throw 'FPC (ppc386.exe) bulunamadi; $env:FPC ayarlayin' }

$outDir = Join-Path $dir 'lib\vdbapi-win32'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Write-Host "vdbapi.dll derleniyor (i386-win32)... FPC=$fpc" -ForegroundColor Cyan

# NOT: degisken adi $args OLMAMALI; PowerShell'da $args yerlesik bir
# otomatik degiskendir ve digerlerini ezdi.
$fpcArgs = @(
    '-O2',                        # optimize
    "-Fu$dir",                    # motor birimleri
    # VDbCore -> VDbCrypt -> DCPcrypt. Bu yollar eklenmezse
    # "Can't find unit dcpcrypt2 used by VDbCrypt" ile derleme duser.
    "-Fu$dir\dcpcrypt",
    "-Fu$dir\dcpcrypt\Ciphers",
    "-Fu$dir\dcpcrypt\Hashes",
    "-FU$outDir",                 # .o/.ppu cikti
    "-FE$dir",                    # .dll cikti
    "$dir\vdbapi.lpr"             # kaynak (TEK kaynak dosyasi son arg olmali)
)

& $fpc @fpcArgs
if ($LASTEXITCODE -ne 0) { throw "derleme basarisiz (kod $LASTEXITCODE)" }

$dll = Join-Path $dir 'vdbapi.dll'
if (-not (Test-Path $dll)) { throw 'vdbapi.dll uretilmedi' }

Write-Host ''
Write-Host 'TAMAM: vdbapi.dll' -ForegroundColor Green
Get-Item $dll | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
