#!/bin/sh
# run_gates.sh - VDB V3 kalici test kapilarini derler ve kosar.
#
# Kullanim:
#   ./tests/run_gates.sh [IS_DIZINI]
#
# IS_DIZINI verilmezse <repo>/build/gates kullanilir. Betik saf `fpc`
# kullanir (Lazarus IDE gerekmez) ve Linux/macOS ile Windows Git Bash'te
# ayni sekilde calisir.
#
# Ortam degiskenleri (hepsi istege bagli):
#   FPC             fpc yolu (varsayilan: PATH'teki `fpc`)
#   VDB_CRYPTO_DLL  OpenSSL libcrypto tam yolu (openssl kapilari icin)
#   VDB_SSL_DLL     OpenSSL libssl tam yolu (TLS kapisi icin)
#   VDB_TLS_FIXTURES  TLS fixture dizini (varsayilan: tests/tls_fixtures)
#
# Cikis kodu: 0 = tum kosan kapilar gecti, 1 = en az bir kapi basarisiz.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=${1:-"$ROOT/build/gates"}
FPC=${FPC:-fpc}

EXE=""
NATIVE_PATH=0
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    EXE=".exe"
    # Git Bash/MSYS kabugu POSIX yolu verir (/d/repo); derleyici ise
    # native Windows ikilisidir ve /d/repo'yu surucu-goreli \d\repo sanar
    # ("Path does not exist"). fpc'ye verilen yollari cygpath ile cevir.
    if command -v cygpath >/dev/null 2>&1; then
      NATIVE_PATH=1
    fi
    ;;
esac

# npath: kabuk islemleri icin POSIX, fpc argumanlari icin native yol.
npath() {
  if [ "$NATIVE_PATH" -eq 1 ]; then
    cygpath -w -- "$1"
  else
    printf '%s' "$1"
  fi
}

mkdir -p "$WORK"
FAILED=0
RUN=0

build_gate() {
  name=$1
  src=$2
  out="$WORK/$name"
  mkdir -p "$out/lib"
  log="$WORK/$name.build.log"
  if "$FPC" -MObjFPC -Scghi -O1 -g -l -vewnhibq \
      "-Fu$(npath "$ROOT")" "-FU$(npath "$out/lib")" "-FE$(npath "$out")" \
      "$(npath "$src")" >"$log" 2>&1; then
    echo "BUILD OK   $name"
    return 0
  fi
  echo "BUILD FAIL $name"
  tail -n 25 "$log"
  FAILED=1
  return 1
}

# run_gate <etiket> <kapi_dizini> <exe_adi> [argumanlar...]
run_gate() {
  label=$1
  dir=$2
  exe=$3
  shift 3
  if [ ! -f "$dir/$exe$EXE" ]; then
    echo "MISSING    $label ($dir/$exe$EXE)"
    FAILED=1
    return
  fi
  RUN=$((RUN + 1))
  log="$WORK/$label.run.log"
  ( cd "$dir" && "./$exe$EXE" "$@" ) >"$log" 2>&1
  rc=$?
  last=$(tail -n 1 "$log")
  if [ "$rc" -eq 0 ]; then
    echo "PASS       $label | $last"
  elif [ "$rc" -eq 77 ]; then
    echo "SKIP       $label | $last"
    RUN=$((RUN - 1))
  else
    echo "FAIL       $label (exit $rc) | $last"
    tail -n 20 "$log"
    FAILED=1
  fi
}

skip_gate() {
  echo "SKIP       $1 ($2)"
}

# --- derleme ---------------------------------------------------------
# crypto_fixtures fixture'lari exe'nin yaninda arar; bu yuzden o kapi
# kaynak dizinine derlenir, digerleri $WORK altina.
FI=$ROOT/tests/crypto_fixtures
# Eski ikili kalmis olabilir; bayat exe "PASS" yanilsamasi uretir.
rm -f "$FI/gen_fixtures$EXE"
# Temiz checkout'ta lib dizini YOKTUR; fpc -FU hedefini kendisi yaratmaz.
# (CI'da tam bu yuzden "BUILD FAIL crypto_fixtures" alindi.)
mkdir -p "$FI/lib"
if "$FPC" -MObjFPC -Scghi -O1 -g -l -vewnhibq \
    "-Fu$(npath "$ROOT")" "-FU$(npath "$FI/lib")" "-FE$(npath "$FI")" \
    "$(npath "$FI/gen_fixtures.lpr")" \
    >"$WORK/gen_fixtures.build.log" 2>&1; then
  echo "BUILD OK   crypto_fixtures"
else
  echo "BUILD FAIL crypto_fixtures"
  tail -n 25 "$WORK/gen_fixtures.build.log"
  FAILED=1
fi

build_gate sql_stubs     "$ROOT/tests/sql_stubs/sql_stubs.lpr"
build_gate sql_fuzz      "$ROOT/tests/sql_fuzz/sql_fuzz.lpr"
build_gate crypto_core   "$ROOT/tests/crypto_core/core_smoke.lpr"
build_gate crypto_base64 "$ROOT/tests/crypto_base64/base64_runner.lpr"
build_gate crypto_selftest "$ROOT/tests/crypto_selftest/selftest_runner.lpr"
build_gate crypto_kat    "$ROOT/tests/crypto_kat/kat_runner.lpr"
build_gate wal_crash     "$ROOT/tests/wal_crash/wal_crash_matrix.lpr"
build_gate kv_wal        "$ROOT/tests/wal_crash/kv_wal_matrix.lpr"
build_gate server_harden "$ROOT/tests/server_harden/server_harden.lpr"
build_gate auth_throttle "$ROOT/tests/server_harden/auth_throttle.lpr"
build_gate tls_client    "$ROOT/tests/tls_client/tls_client_gate.lpr"

# --- kosum -----------------------------------------------------------
unset VDB_CRYPTO_PROVIDER 2>/dev/null || true
unset VDB_CRYPTO_DLL 2>/dev/null || true

run_gate sql_stubs      "$WORK/sql_stubs"      sql_stubs
run_gate sql_fuzz       "$WORK/sql_fuzz"       sql_fuzz
run_gate crypto_core    "$WORK/crypto_core"    core_smoke
run_gate crypto_base64  "$WORK/crypto_base64"  base64_runner
run_gate fixtures_builtin "$FI"                gen_fixtures verify
run_gate crypto_kat     "$WORK/crypto_kat"     kat_runner
run_gate wal_crash      "$WORK/wal_crash"      wal_crash_matrix
run_gate kv_wal         "$WORK/kv_wal"         kv_wal_matrix
run_gate server_harden  "$WORK/server_harden"  server_harden
run_gate auth_throttle  "$WORK/auth_throttle"  auth_throttle

run_gate selftest_builtin "$WORK/crypto_selftest" selftest_runner builtin

# OpenSSL opt-in kapilari: yalniz kutuphane gercekten varsa kosar.
if [ -n "${VDB_CRYPTO_DLL:-}" ]; then
  VDB_CRYPTO_PROVIDER=openssl VDB_CRYPTO_DLL="$VDB_CRYPTO_DLL" \
    run_gate fixtures_openssl "$FI" gen_fixtures verify
  VDB_CRYPTO_PROVIDER=openssl VDB_CRYPTO_DLL="$VDB_CRYPTO_DLL" \
    run_gate selftest_openssl "$WORK/crypto_selftest" selftest_runner openssl
else
  skip_gate fixtures_openssl "VDB_CRYPTO_DLL yok"
  skip_gate selftest_openssl "VDB_CRYPTO_DLL yok"
fi

if [ -n "${VDB_SSL_DLL:-}" ] || [ -z "$EXE" ]; then
  VDB_TLS_FIXTURES=${VDB_TLS_FIXTURES:-"$ROOT/tests/tls_fixtures"} \
    run_gate tls_client "$WORK/tls_client" tls_client_gate
else
  # Windows'ta libssl adi bilinmiyorsa kapi 77 ile atlar; yine de
  # denemesi zararsiz. Bos VDB_SSL_DLL ile kosar.
  run_gate tls_client "$WORK/tls_client" tls_client_gate
fi

echo "---"
echo "KOSAN KAPI: $RUN"
if [ "$FAILED" -ne 0 ]; then
  echo "SONUC: FAIL"
  exit 1
fi
echo "SONUC: PASS"
