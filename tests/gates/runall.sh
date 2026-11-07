#!/bin/sh
# Tum VDB kapilarini tek komutla derler ve kosar (Linux / macOS / Git Bash).
#
# Kullanim:  tests/gates/runall.sh <calisma-dizini> [fpc-yolu] [-B]
#   <calisma-dizini>  ZORUNLU. Kapilar bu dizin altinda ayri alt dizinler
#                     acar; onceden var olmasi gerekmez.
#   [fpc-yolu]        Varsayilan: fpc (PATH'ten).
#   -B                Birimleri de bastan derle (CI'da gerek yok: her kosu
#                     taze; yerelde kod degistiysE kullan).
#
# Cikis: 0 = tum kapilar gecti; 1 = en az bir kapi kaldi.
# Kapilar ve beklenen ciktilar .github/workflows/ci.yml ile ayni tablodan
# gelir; yeni kapi eklenince IKISI guncellenmelidir.

set -u

# --- argumanlar ---
if [ "$#" -lt 1 ]; then
  echo "kullanim: $0 <calisma-dizini> [fpc-yolu] [-B]" >&2
  exit 2
fi
WORK="$1"
shift || true
FPC="fpc"
FORCEB=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -B) FORCEB="-B" ;;
    *) FPC="$1" ;;
  esac
  shift
done

# --- yollar ---
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 2
BIN="$WORK/bin"
UNITDIR="$WORK/units"
mkdir -p "$BIN" "$UNITDIR" || exit 2

# Yerelde calistirirken taze dizin onerisi: kapilar kendi alt dizinlerini
# kendisi olusturur; eski icerik silinmez (rm -rf yasagi).
mkdir -p "$WORK" || exit 2

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) EXT=".exe" ;;
  *) EXT="" ;;
esac

FPCFLAGS="-O2 -XX $FORCEB -FU$UNITDIR -Fudcpcrypt -Fudcpcrypt/Ciphers -Fudcpcrypt/Hashes"

FAIL=0
PASS=0

# GitHub Actions ek aciklamasi: genel repolarda kimlik dogrulamadan
# OKUNABILEN tek kanal (check-runs API). Yeni satirlar %0A ile kodlanir.
annot() {
  _t="$1"; shift
  _m=$(printf '%s' "$*" | tr '\r' ' ' | tr '\n' '%' | sed 's/%/%0A/g' |
    cut -c1-600)
  echo "::error title=$_t::$_m"
}

# derle <lpr-yolu> <cikti-adi>
derle() {
  _lpr="$1"; _ad="$2"
  echo "--- derle: $_ad"
  if ! "$FPC" $FPCFLAGS -o"$BIN/$_ad$EXT" "$_lpr" > "$WORK/$_ad.build.log" 2>&1; then
    echo "  DERLEME HATASI ($_ad):"
    grep -E "Error|Fatal|error" "$WORK/$_ad.build.log" | head -5
    annot "$_ad derleme" "$(grep -E 'Error|Fatal' "$WORK/$_ad.build.log" | head -4 | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
    return 1
  fi
  return 0
}

# kos <ad> <beklenen-dize> [argumanlar...]
kos() {
  _ad="$1"; _bek="$2"; shift 2
  _d="$WORK/$_ad"
  mkdir -p "$_d" || exit 2
  echo "--- kapi: $_ad $*"
  if ! "$BIN/$_ad$EXT" "$@" > "$WORK/$_ad.run.log" 2>&1; then
    echo "  KOSMA HATASI ($_ad) — son satirlar:"
    tail -10 "$WORK/$_ad.run.log"
    annot "$_ad kapi" "$(tail -4 "$WORK/$_ad.run.log" | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
    return 1
  fi
  if ! grep -q "$_bek" "$WORK/$_ad.run.log"; then
    echo "  BASARISIZ ($_ad): '$_bek' bulunamadi — son satirlar:"
    tail -10 "$WORK/$_ad.run.log"
    annot "$_ad kapi" "beklenen: $_bek | $(tail -3 "$WORK/$_ad.run.log" | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
    return 1
  fi
  if grep -q "kalan=" "$WORK/$_ad.run.log" && ! grep -q "kalan=0" "$WORK/$_ad.run.log"; then
    echo "  BASARISIZ ($_ad): kalan > 0 — son satirlar:"
    tail -10 "$WORK/$_ad.run.log"
    annot "$_ad kapi" "kalan>0 | $(tail -3 "$WORK/$_ad.run.log" | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
    return 1
  fi
  echo "  GECTI"
  PASS=$((PASS + 1))
  return 0
}

# --- kapilar (sira: cekirdekten disa) ---

derle tests/gates/pagechk.lpr pagechk && kos pagechk "SAYFA CEKIRDEGI DOGRULANDI"
derle tests/gates/storechk.lpr storechk && kos storechk "SAYFA DEPOSU DOGRULANDI" "$WORK/storechk"
derle tests/gates/heapchk.lpr heapchk && kos heapchk "HEAP DOGRULANDI" "$WORK/heapchk"
derle tests/gates/crashtest.lpr crashtest && kos crashtest "COKME KURTARMA DOGRULANDI" "$WORK/crashtest"
derle tests/gates/dropchk.lpr dropchk && \
  for m in 1 2 3; do
    kos dropchk "TEMIZ: bozulma yok" "$WORK/dropchk" 100000 "$m"
  done
derle tests/gates/idxchk.lpr idxchk && kos idxchk "KALICI DIZIN DOGRULANDI" "$WORK/idxchk" 50000
derle tests/gates/idxcache.lpr idxcache && kos idxcache "INDEKS ONBELLEGI TUTARLILIGI DOGRULANDI" "$WORK/idxcache"
derle tests/gates/backendchk.lpr backendchk && kos backendchk "BACKEND DIKISI DOGRULANDI" "$WORK/backendchk" 5000
derle tests/gates/colmapchk.lpr colmapchk && kos colmapchk "KOLON HARITASI ONBELLEGI DOGRULANDI" "$WORK/colmapchk"
derle tests/gates/mvchk.lpr mvchk && kos mvchk "MATERIALIZED VIEW KALICILIGI DOGRULANDI" "$WORK/mvchk"
derle tests/gates/aggchk.lpr aggchk && kos aggchk "AGGREGATE HASSASIYETI DOGRULANDI" "$WORK/aggchk"
derle tests/gates/mmchk.lpr mmchk && kos mmchk "MM SOZLESMESI DOGRULANDI"
derle tests/gates/poolchk.lpr poolchk && kos poolchk "HAVUZ HATA YOLU DOGRULANDI" "$WORK/poolchk"
derle tests/gates/poolsafe.lpr poolsafe && kos poolsafe "HAVUZ SAHIPLIK SOZLESMESI DOGRULANDI" "$WORK/poolsafe"
derle tests/gates/readlockchk.lpr readlockchk && kos readlockchk "OKUMA KILIDI SIZINTISI YOK" "$WORK/readlockchk"
derle tests/gates/commitfailchk.lpr commitfailchk && kos commitfailchk "COMMIT HATA YOLLARI DOGRULANDI" "$WORK/commitfailchk"
derle tests/gates/genchk.lpr genchk && kos genchk "DB NESLI VE DURABIL LSN DOGRULANDI" "$WORK/genchk"
derle tests/gates/v3sqlchk.lpr v3sqlchk && kos v3sqlchk "V3 SQL KATMANI DOGRULANDI" "$WORK/v3sqlchk" 1200
derle tests/gates/migchk.lpr migchk && kos migchk "V2 -> V3 GOCU DOGRULANDI" "$WORK/migchk" 5000
derle tests/gates/factorychk.lpr factorychk && kos factorychk "FACTORY DOGRULANDI" "$WORK/factorychk"
derle tests/gates/logchk.lpr logchk && kos logchk "DEGISIM GUNLUGU DOGRULANDI" "$WORK/logchk"
derle tests/gates/pitrchk.lpr pitrchk && kos pitrchk "PITR DOGRULANDI" "$WORK/pitrchk"
derle tests/gates/btreechk.lpr btreechk && kos btreechk "B+TREE INDEKS DOGRULANDI" 50000
derle tests/gates/replchk.lpr replchk && kos replchk "REPLIKASYON DOGRULANDI" "$WORK/replchk"
derle tests/gates/lockchk.lpr lockchk && kos lockchk "COK OKUYUCU / TEK YAZICI DOGRULANDI" "$WORK/lockchk"
derle tests/gates/snapchk.lpr snapchk && kos snapchk "kalan=0" "$WORK/snapchk"
derle tests/gates/prochk.lpr prochk && kos prochk "kalan=0" "$WORK/prochk"
derle tests/gates/concurchk.lpr concurchk && kos concurchk "ESZAMANLILIK DOGRULANDI" "$WORK/concurchk"
derle tests/sql/sqltest.lpr sqltest && kos sqltest "TUM SQL TESTLERI GECTI" "$WORK/sqltest" --backend=v3

echo "================================"
echo "SONUC: gecen=$PASS kalan=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "KAPILAR BASARISIZ"
  exit 1
fi
echo "TUM KAPILAR GECTI"
