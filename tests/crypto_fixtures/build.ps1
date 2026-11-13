# Derleme kalibi: -Fu bayraklari yola BITISIK yazilmali (bosluklu bicim sessizce bozuyor).
Set-Location D:\veritabani\tests\crypto_fixtures
fpc -MObjFPC -Scghi -O1 -g -l -vewnhibq -FuD:\veritabani -FuD:\veritabani\dcpcrypt -FuD:\veritabani\dcpcrypt\Ciphers -FuD:\veritabani\dcpcrypt\Hashes "-FUD:\veritabani\tests\crypto_fixtures\lib" gen_fixtures.lpr
Write-Output "FPC_EXIT=$LASTEXITCODE"
