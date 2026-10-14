# build_testext.ps1 - vdbtestext.dll derler (Windows / i386-win32).
#
# R-21 Full: `CREATE EXTENSION` icin dinamik yuklenebilir ORNEK eklenti.
# sqltest T99_Extension grubu bu DLL'i (varsa) yukleyip gercek sembol
# cagrisi yapar; DLL yoksa grup kontrollu sekilde atlanir.
#
# Kullanim:  powershell -ExecutionPolicy Bypass -File build_testext.ps1

$ErrorActionPreference = 'Stop'

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

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

$outDir = Join-Path $dir 'lib\vdbtestext-win32'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Write-Host "vdbtestext.dll derleniyor (i386-win32)... FPC=$fpc" -ForegroundColor Cyan

$fpcArgs = @(
    '-O2',
    "-FU$outDir",
    "-FE$dir",
    "$dir\vdbtestext.lpr"
)

& $fpc @fpcArgs
if ($LASTEXITCODE -ne 0) { throw "derleme basarisiz (kod $LASTEXITCODE)" }

# R-21: eski ABI surumlu ikinci eklenti (surum-kapisi testi icin).
$fpcArgs2 = @(
    '-O2',
    "-FU$outDir",
    "-FE$dir",
    "$dir\vdboldtext.lpr"
)

& $fpc @fpcArgs2
if ($LASTEXITCODE -ne 0) { throw "oldext derlemesi basarisiz (kod $LASTEXITCODE)" }

$dll = Join-Path $dir 'vdbtestext.dll'
$dll2 = Join-Path $dir 'vdboldtext.dll'
if (-not (Test-Path $dll)) { throw 'vdbtestext.dll uretilmedi' }
if (-not (Test-Path $dll2)) { throw 'vdboldtext.dll uretilmedi' }

Write-Host ''
Write-Host 'TAMAM: vdbtestext.dll + vdboldtext.dll' -ForegroundColor Green
Get-Item $dll, $dll2 | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
