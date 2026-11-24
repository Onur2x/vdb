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
# WORK goreli verilirse mutlak yola cevir. integrity_check kapisi vdbcheck
# yolunu alt surece arguman olarak verir; alt surec kendi calisma dizinine
# gectigi icin goreli yol bulunamaz (EProcess: Executable not found).
case "$WORK" in
  /*|[A-Za-z]:[\\/]*) ;;
  *) WORK="$ROOT/$WORK" ;;
esac
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
build_gate sql_matrix    "$ROOT/tests/sql_matrix/sql_matrix.lpr"
build_gate sql_fuzz      "$ROOT/tests/sql_fuzz/sql_fuzz.lpr"
build_gate sql_differential "$ROOT/tests/sql_differential/sql_differential.lpr"
build_gate crypto_core   "$ROOT/tests/crypto_core/core_smoke.lpr"
build_gate crypto_base64 "$ROOT/tests/crypto_base64/base64_runner.lpr"
build_gate crypto_selftest "$ROOT/tests/crypto_selftest/selftest_runner.lpr"
build_gate crypto_kat    "$ROOT/tests/crypto_kat/kat_runner.lpr"
build_gate wal_crash     "$ROOT/tests/wal_crash/wal_crash_matrix.lpr"
build_gate kv_wal        "$ROOT/tests/wal_crash/kv_wal_matrix.lpr"
build_gate backup_restore "$ROOT/tests/backup_restore/backup_restore.lpr"
build_gate page_integrity "$ROOT/tests/page_integrity/page_integrity.lpr"
build_gate btree_integrity "$ROOT/tests/btree_integrity/btree_integrity.lpr"
build_gate perf_baseline  "$ROOT/tests/perf_baseline/perf_baseline.lpr"
build_gate single_file    "$ROOT/tests/single_file/single_file.lpr"
build_gate region_stream  "$ROOT/tests/region_stream/region_stream.lpr"
build_gate multiproc      "$ROOT/tests/multiproc/multiproc.lpr"
build_gate maint_lock     "$ROOT/tests/maint_lock/maint_lock.lpr"
build_gate pg_portal_stream "$ROOT/tests/pg_portal_stream/pg_portal_stream.lpr"
build_gate serializable_tx "$ROOT/tests/serializable_tx/serializable_tx.lpr"
build_gate pg_msg_nul     "$ROOT/tests/pg_msg_nul/pg_msg_nul.lpr"
build_gate merge_hash     "$ROOT/tests/merge_hash/merge_hash.lpr"
build_gate null_empty      "$ROOT/tests/null_empty/null_empty.lpr"
build_gate crash_points   "$ROOT/tests/crash_points/crash_points.lpr"
build_gate vdbcheck        "$ROOT/vdbcheck.lpr"
build_gate integrity_check "$ROOT/tests/integrity_check/integrity_check.lpr"
build_gate cache_metrics   "$ROOT/tests/cache_metrics/cache_metrics.lpr"
build_gate format_compat   "$ROOT/tests/format_compat/format_compat.lpr"
build_gate portability     "$ROOT/tests/portability/portability.lpr"
build_gate multi_writer    "$ROOT/tests/multi_writer/multi_writer.lpr"
build_gate bench_report    "$ROOT/tests/bench_report/bench_report.lpr"
build_gate sql_features    "$ROOT/tests/sql_features/sql_features.lpr"
build_gate sql_authorization "$ROOT/tests/sql_authorization/sql_authorization.lpr"
build_gate sql_atomicity   "$ROOT/tests/sql_atomicity/sql_atomicity.lpr"
build_gate wal_recovery    "$ROOT/tests/wal_recovery/wal_recovery.lpr"
build_gate freelist        "$ROOT/tests/freelist/freelist.lpr"
build_gate limits          "$ROOT/tests/limits/limits_gate.lpr"
build_gate sql_memory      "$ROOT/tests/sql_memory/sql_memory.lpr"
build_gate cache_pressure  "$ROOT/tests/cache_pressure/cache_pressure.lpr"
build_gate page_corrupt    "$ROOT/tests/page_corrupt/page_corrupt.lpr"
build_gate server_failure  "$ROOT/tests/server_failure/server_failure.lpr"
build_gate server_harden "$ROOT/tests/server_harden/server_harden.lpr"
build_gate auth_throttle "$ROOT/tests/server_harden/auth_throttle.lpr"
build_gate disk_full      "$ROOT/tests/disk_full/disk_full.lpr"
build_gate txn_limit      "$ROOT/tests/txn_limit/txn_limit.lpr"
build_gate oom            "$ROOT/tests/oom/oom.lpr"
build_gate btree_scale    "$ROOT/tests/btree_scale/btree_scale.lpr"
build_gate wal_limit      "$ROOT/tests/wal_limit/wal_limit.lpr"
build_gate net_fuzz       "$ROOT/tests/net_fuzz/net_fuzz.lpr"
build_gate network_limits "$ROOT/tests/network_limits/network_limits.lpr"
build_gate pg_cancel      "$ROOT/tests/pg_cancel/pg_cancel.lpr"
build_gate btree_disk     "$ROOT/tests/btree_disk/btree_disk.lpr"
build_gate sql_scale      "$ROOT/tests/sql_scale/sql_scale.lpr"
build_gate sql_index_scale "$ROOT/tests/sql_index_scale/sql_index_scale.lpr"
build_gate soak          "$ROOT/tests/soak/soak.lpr"
build_gate tls_client    "$ROOT/tests/tls_client/tls_client_gate.lpr"
build_gate interop_format "$ROOT/tests/interop_format/interop_format.lpr"
build_gate interop_external "$ROOT/tests/interop_external/interop_external.lpr"
build_gate crypto_interop "$ROOT/tests/crypto_interop/crypto_interop.lpr"
build_gate crypto_interop_ext "$ROOT/tests/crypto_interop_ext/crypto_interop_ext.lpr"
build_gate bench_sqlite  "$ROOT/tests/bench_sqlite/bench_sqlite.lpr"

# SKILL12: kalici disk indeksi kapilari (entegrasyon, cokme matrisi, olcek).
build_gate disk_index_integration "$ROOT/tests/disk_index_integration/dji.lpr"
build_gate disk_index_crash "$ROOT/tests/disk_index_crash/dixcrash.lpr"
build_gate disk_index_scale "$ROOT/tests/disk_index_scale/dixscale.lpr"

# SKILL11: dis siralama (spill) cekirdegi + davranis kapisi.
build_gate spill_core "$ROOT/tests/spill_core/spill_core.lpr"
build_gate stream_spill "$ROOT/tests/stream_spill/stream_spill.lpr"

# SKILL14: kesin DECIMAL/NUMERIC. Cekirdek kutuphane kendi kendini dogrular;
# decimal_numeric motorun tam yolunu (tip, aritmetik, karsilastirma, kumeleme,
# kalicilik, Arrow/Parquet gidis-donus) kapsar.
build_gate decimal_core "$ROOT/tests/decimal_core/decimal_core.lpr"
build_gate decimal_numeric "$ROOT/tests/decimal_numeric/decimal_numeric.lpr"

# SKILL17: gercekci olcek kosusu ve SQLite karsilastirmasi. Kapida iki boyut
# (5.000 / 100.000) yazilir, okunur, guncellenir, silinir, yedeklenip geri
# yuklenir; iki motorun 13 kontrol toplami karsilastirilir. Python sqlite3
# (stdlib) yoksa kapi 77 ile SKIP verir ve PASS sayilmaz.
build_gate bench_scale "$ROOT/tests/bench_scale/bench_scale.lpr"

# SKILL17: gercek PostgreSQL istemci matrisi (psql, libpq, psycopg, JDBC,
# Npgsql) + saf Python protokol bacagi. Makinede GERCEK istemci yoksa kapi
# 77 ile SKIP verir (PASS sayilmaz) ve gerekceyi SKIP_REASON.txt'e yazar;
# wire bacagi kosturulur ama uyumluluk kaniti sayilmaz.
build_gate pg_client_matrix "$ROOT/tests/pg_client_matrix/pg_client_matrix.lpr"

# --- kosum -----------------------------------------------------------
unset VDB_CRYPTO_PROVIDER 2>/dev/null || true
unset VDB_CRYPTO_DLL 2>/dev/null || true

run_gate sql_stubs      "$WORK/sql_stubs"      sql_stubs
run_gate sql_matrix     "$WORK/sql_matrix"     sql_matrix
run_gate sql_fuzz       "$WORK/sql_fuzz"       sql_fuzz
run_gate sql_differential "$WORK/sql_differential" sql_differential \
  "$(npath "$ROOT/tests/sql_differential/corpus.txt")"
run_gate crypto_core    "$WORK/crypto_core"    core_smoke
run_gate crypto_base64  "$WORK/crypto_base64"  base64_runner
run_gate fixtures_builtin "$FI"                gen_fixtures verify
run_gate crypto_kat     "$WORK/crypto_kat"     kat_runner "$ROOT/tests/crypto_kat/cavp_aes256gcm.txt"
run_gate wal_crash      "$WORK/wal_crash"      wal_crash_matrix
run_gate kv_wal         "$WORK/kv_wal"         kv_wal_matrix
run_gate backup_restore "$WORK/backup_restore" backup_restore
run_gate page_integrity "$WORK/page_integrity" page_integrity
run_gate btree_integrity "$WORK/btree_integrity" btree_integrity
run_gate perf_baseline  "$WORK/perf_baseline"  perf_baseline
run_gate single_file    "$WORK/single_file"    single_file
run_gate region_stream  "$WORK/region_stream"  region_stream
run_gate multiproc      "$WORK/multiproc"      multiproc
run_gate maint_lock     "$WORK/maint_lock"     maint_lock
run_gate pg_portal_stream "$WORK/pg_portal_stream" pg_portal_stream
run_gate serializable_tx "$WORK/serializable_tx" serializable_tx
run_gate pg_msg_nul     "$WORK/pg_msg_nul"     pg_msg_nul
run_gate merge_hash     "$WORK/merge_hash"     merge_hash
run_gate null_empty      "$WORK/null_empty"     null_empty
run_gate crash_points   "$WORK/crash_points"   crash_points
run_gate integrity_check "$WORK/integrity_check" integrity_check \
  "$(npath "$WORK/vdbcheck/vdbcheck$EXE")"
run_gate cache_metrics  "$WORK/cache_metrics"   cache_metrics
run_gate format_compat  "$WORK/format_compat"   format_compat
run_gate portability    "$WORK/portability"     portability
run_gate multi_writer   "$WORK/multi_writer"    multi_writer
run_gate bench_report   "$WORK/bench_report"    bench_report
run_gate sql_features   "$WORK/sql_features"    sql_features
run_gate sql_authorization "$WORK/sql_authorization" sql_authorization
run_gate sql_atomicity  "$WORK/sql_atomicity"   sql_atomicity
run_gate wal_recovery   "$WORK/wal_recovery"    wal_recovery
run_gate freelist       "$WORK/freelist"        freelist
run_gate limits         "$WORK/limits"          limits_gate
run_gate sql_memory     "$WORK/sql_memory"     sql_memory
run_gate cache_pressure "$WORK/cache_pressure"  cache_pressure
run_gate page_corrupt   "$WORK/page_corrupt"    page_corrupt
run_gate server_failure "$WORK/server_failure"  server_failure
run_gate server_harden  "$WORK/server_harden"  server_harden
run_gate auth_throttle  "$WORK/auth_throttle"  auth_throttle
run_gate disk_full      "$WORK/disk_full"      disk_full
run_gate txn_limit      "$WORK/txn_limit"      txn_limit
run_gate oom            "$WORK/oom"            oom
run_gate btree_scale    "$WORK/btree_scale"    btree_scale
run_gate wal_limit      "$WORK/wal_limit"      wal_limit
run_gate net_fuzz       "$WORK/net_fuzz"       net_fuzz
run_gate network_limits "$WORK/network_limits" network_limits
run_gate pg_cancel      "$WORK/pg_cancel"      pg_cancel
run_gate btree_disk     "$WORK/btree_disk"     btree_disk
run_gate sql_scale      "$WORK/sql_scale"      sql_scale
run_gate sql_index_scale "$WORK/sql_index_scale" sql_index_scale
run_gate soak           "$WORK/soak"           soak

# SKILL12: disk indeksi. Olcek kapisi CI'da 200k satir ile kosar; elle
# daha buyuk deger verilebilir (10M 32-bit ikilide CREATE INDEX'in bellek
# insasi yuzunden calismaz - bkz. docs/engineering/CI.md).
run_gate disk_index_integration "$WORK/disk_index_integration" dji
run_gate disk_index_crash "$WORK/disk_index_crash" dixcrash
run_gate disk_index_scale "$WORK/disk_index_scale" dixscale 200000

# SKILL11: spill cekirdegi (bicim/kararlilik) ve imlec dis siralama kapisi.
# stream_spill 1M satir ORDER BY icerir (~50 sn); butce diskte, %TEMP%
# degil kendi calisma dizininde tutulur.
run_gate spill_core "$WORK/spill_core" spill_core
run_gate stream_spill "$WORK/stream_spill" stream_spill

# SKILL14: kesin DECIMAL. decimal_core saf kutuphane testidir (hizli);
# decimal_numeric motorun SQL, kalicilik ve Arrow/Parquet DECIMAL yolunu
# uctan uca surer.
run_gate decimal_core "$WORK/decimal_core" decimal_core
run_gate decimal_numeric "$WORK/decimal_numeric" decimal_numeric

# SKILL17: olcek/benchmark kapisi. Uzun soak (1h/6h/24h) burada KOSMAZ;
# kapi bunu "SOAK ... NOT-RUN" satirlariyla acikca yazar.
run_gate bench_scale "$WORK/bench_scale" bench_scale \
  "$(npath "$WORK/bench_scale")" "5000,100000" \
  "$(npath "$ROOT/tests/bench_scale")"

# SKILL17: gercek istemci matrisi. Ikinci arg betik dizinidir. Gercek
# istemci yoksa cikis 77'dir: SKIP, PASS degildir.
run_gate pg_client_matrix "$WORK/pg_client_matrix" pg_client_matrix \
  "$(npath "$WORK/pg_client_matrix")" \
  "$(npath "$ROOT/tests/pg_client_matrix")"

# SKILL6 08: interop / kripto / bench kapilari.
# Dis arac (pyarrow) gerektiren kapilar arac yoksa 77 ile SKIP verir ve
# ASLA PASS sayilmaz. pyarrow depo disinda bir dizindeyse VDB_PY_LIBS ile
# gosterilebilir; VDB_INTEROP_PY ile yorumlayici secilebilir.
run_gate interop_format "$WORK/interop_format" interop_format \
  "$(npath "$ROOT/tests/interop_format/fixtures")"
run_gate interop_external "$WORK/interop_external" interop_external \
  "$(npath "$WORK/interop_external")" "$(npath "$ROOT/tests/interop_external")"
run_gate crypto_interop "$WORK/crypto_interop" crypto_interop
run_gate crypto_interop_ext "$WORK/crypto_interop_ext" crypto_interop_ext \
  "$(npath "$ROOT/tests/crypto_interop_ext")"
run_gate bench_sqlite   "$WORK/bench_sqlite"   bench_sqlite \
  "$(npath "$WORK/bench_sqlite")" "$(npath "$ROOT/tests/bench_sqlite")"

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
