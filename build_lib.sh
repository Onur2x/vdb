#!/bin/sh
# build_lib.sh - vdbapi paylasilan kutuphanesini derler (Linux / macOS / BSD).
#
# R-23 Cross-Platform DLL / C API
# -------------------------------
# Motor saf FPC RTL'e indirgendi: LazUtils/FileUtil bagimliligi YOKTUR.
# Bu yuzden AYNI kaynak (vdbapi.lpr) her platformda ek harici kutuphane
# olmadan derlenir. Cikti adi platforma gore belirlenir:
#
#   Linux / BSD : libvdbapi.so
#   macOS       : libvdbapi.dylib
#   Windows     : vdbapi.dll    (bkz. build_dll.ps1 / build_lib.bat)
#
# Cagri sozlesmesi (bkz. vdbapi.h VDB_CALL): 32-bit x86 Linux/BSD'de
# `stdcall`, x86_64/aarch64'ta platform varsayilani. Pascal tarafindaki
# `stdcall` 64-bit'te varsayilan ABI ile ayni oldugundan tek isaret
# yeterlidir; baslik ve kaynak boylece tutarli kalir.
#
# KULLANIM
#   ./build_lib.sh                     # yerel FPC (PATH'teki `fpc`)
#   FPC=/opt/fpc/bin/fpc ./build_lib.sh
#   ./build_lib.sh -Tlinux             # capraz derleme (cross target)
#   ./build_lib.sh -Tdarwin
#
# NOT: -Mdelphi BILINCLI olarak verilmez. Birimlerin kendi
# `{$mode delphi}` yonergesi vardir; VDbCrc32.pas icindeki bir yorumda
# gecen `{$mode delphi}` dizisi -Mdelphi ile erken kapanip derlemeyi
# bozabiliyor (bkz. build_dll.ps1 ayni notu). FPC ontanilan modda
# ic ice yorumlari dogru isler.

set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FPC=${FPC:-fpc}

# ---- 1) Hedef isletim sistemini belirle -----------------------------
OS=$(uname -s 2>/dev/null || echo unknown)
case "$OS" in
  Linux)                  LIBEXT=so;    TARGET=linux   ;;
  Darwin)                 LIBEXT=dylib; TARGET=darwin  ;;
  FreeBSD|OpenBSD|NetBSD) LIBEXT=so;    TARGET=freebsd ;;
  *)                      LIBEXT=so;    TARGET=linux   ;;
esac

# Capraz derleme: komut satirindan -T<os> gecildiyse onu kullan.
TFLAG=""
for a in "$@"; do
  case "$a" in
    -Tlinux)   LIBEXT=so;    TARGET=linux;   TFLAG="$a" ;;
    -Tdarwin)  LIBEXT=dylib; TARGET=darwin;  TFLAG="$a" ;;
    -Tfreebsd) LIBEXT=so;    TARGET=freebsd; TFLAG="$a" ;;
    -T*)       TFLAG="$a" ;;
  esac
done

OUTDIR="$DIR/lib/vdbapi-$TARGET"
mkdir -p "$OUTDIR"

echo "vdbapi kutuphanesi derleniyor: $TARGET (.$LIBEXT)"

# ---- 2) Derle -------------------------------------------------------
# shellcheck disable=SC2086
"$FPC" \
  -O2 \
  $TFLAG \
  -Fu"$DIR" \
  -Fu"$DIR/dcpcrypt" \
  -Fu"$DIR/dcpcrypt/Ciphers" \
  -Fu"$DIR/dcpcrypt/Hashes" \
  -FU"$OUTDIR" \
  -FE"$DIR" \
  "$DIR/vdbapi.lpr"

# ---- 3) Sonucu dogrula ---------------------------------------------
LIB="$DIR/libvdbapi.$LIBEXT"
if [ ! -f "$LIB" ]; then
  echo "HATA: $LIB uretilmedi" >&2
  exit 1
fi

echo "TAMAM: $LIB"
ls -l "$LIB"
