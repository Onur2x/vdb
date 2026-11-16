#!/usr/bin/env bash
# Canli PostgreSQL diferansiyel kosusu (SKILL4 §5 / CI isi
# sql_differential_postgres). Varsayilan kapilarda bu adim KOSMAZ; korpus
# karsilastirmasi CI'da ayri bir is olarak ve yalniz psql + servis varken
# calisir.
#
# Kullanim:
#   tests/sql_differential/run_pg.sh <corpus.txt> <sql_differential_exe> <is_dizini>
#
# Ortam:
#   PGDATABASE / PGHOST / PGPORT / PGUSER / PGPASSWORD  (psql standardi)
#   VDB_PG_DSN  verilirse tek parca baglanti dizesi olarak kullanilir.
#
# Cikis kodlari:
#   0  karsilastirma kosuldu ve gecti
#   77 SKIP: psql yok veya baglanti kurulamadi (PASS sayilmaz)
#   1  karsilastirma kosuldu ve fark bulundu
set -u

CORPUS=${1:-}
GATE=${2:-}
WORKDIR=${3:-}

if [ -z "$CORPUS" ] || [ -z "$GATE" ] || [ -z "$WORKDIR" ]; then
  echo "kullanim: run_pg.sh <corpus.txt> <sql_differential_exe> <is_dizini>"
  exit 2
fi
if [ ! -f "$CORPUS" ] || [ ! -x "$GATE" ]; then
  echo "FAIL girdi | korpus veya kapi exe bulunamadi"
  exit 2
fi
if ! command -v psql >/dev/null 2>&1; then
  echo "SKIP pg-live | psql yok (canli PostgreSQL karsilastirmasi kosmadi)"
  exit 77
fi

mkdir -p "$WORKDIR"
EMIT="$WORKDIR/emit.sql"
PGOUT="$WORKDIR/pg.out"

"$GATE" "$CORPUS" "--emit=$EMIT" > "$WORKDIR/emit.log" 2>&1
if [ $? -ne 0 ] || [ ! -s "$EMIT" ]; then
  echo "FAIL emit | psql betigi uretilemedi"
  tail -n 20 "$WORKDIR/emit.log"
  exit 1
fi

if [ -n "${VDB_PG_DSN:-}" ]; then
  psql "$VDB_PG_DSN" -v ON_ERROR_STOP=1 -f "$EMIT" > "$PGOUT" 2> "$WORKDIR/psql.err"
else
  psql -v ON_ERROR_STOP=1 -f "$EMIT" > "$PGOUT" 2> "$WORKDIR/psql.err"
fi
if [ $? -ne 0 ]; then
  echo "SKIP pg-live | PostgreSQL baglantisi kurulamadi (PASS sayilmaz)"
  tail -n 5 "$WORKDIR/psql.err"
  exit 77
fi

"$GATE" "$CORPUS" "--pg=$PGOUT"
RC=$?
exit $RC
