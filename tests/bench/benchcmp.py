"""VDB v3 kiyas takimi — SQLite tarafi (Sprint 0).

Ayni is yuku, ayni olcum noktalari. Sonuclar benchcmp.pas ile kiyaslanir.

Kullanim:
    python benchcmp.py <calisma_dizini> [satir] [tekrar]

Ortam notu: synchronous=FULL + journal_mode=DELETE secildi; bu, VDB'nin
her commit'te fsync yapan varsayilanina karsilik gelir.
"""
import os
import sqlite3
import statistics
import sys
import time


def ms(t0):
    return (time.perf_counter() - t0) * 1000.0


def one_trial(base, n_row, n_rep, pkv):
    d = os.path.join(base, 'run')
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, 's.db')
    for f in (p, p + '-journal', p + '-wal', p + '-shm'):
        if os.path.exists(f):
            os.remove(f)

    con = sqlite3.connect(p, isolation_level=None)
    con.execute('PRAGMA journal_mode=DELETE')
    con.execute('PRAGMA synchronous=FULL')
    con.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT)')

    t0 = time.perf_counter()
    con.execute('BEGIN')
    con.executemany(
        'INSERT INTO t(id,a,b) VALUES (?,?,?)',
        ((j, j * 3, 'satir-' + str(j)) for j in range(1, n_row + 1)),
    )
    con.execute('COMMIT')
    ms_batch = ms(t0)

    t0 = time.perf_counter()
    ins = 'INSERT INTO t(id,a,b) VALUES (?,?,?)'
    for j in range(1, n_rep + 1):
        con.execute(ins, (1000000 + j, j, 'auto'))
    ms_auto = ms(t0)

    t0 = time.perf_counter()
    for _ in range(n_rep):
        con.execute('SELECT 1').fetchone()
    ms_parse = ms(t0)

    t0 = time.perf_counter()
    for _ in range(n_rep):
        con.execute('SELECT a FROM t WHERE id=?', (pkv,)).fetchone()
    ms_pk = ms(t0)

    t0 = time.perf_counter()
    con.execute('SELECT COUNT(*) FROM t').fetchone()
    ms_count = ms(t0)

    size = os.path.getsize(p)
    con.close()

    t0 = time.perf_counter()
    con = sqlite3.connect(p, isolation_level=None)
    con.execute('SELECT COUNT(*) FROM t').fetchone()
    ms_open = ms(t0)
    con.close()
    return ms_batch, ms_auto, ms_parse, ms_pk, ms_count, ms_open, size


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.environ.get('TEMP', '.'), 'sqlbenchcmp')
    n_row = int(sys.argv[2]) if len(sys.argv) > 2 else 200000
    n_rep = int(sys.argv[3]) if len(sys.argv) > 3 else 20000
    trials = 3
    pkv = (n_row * 5) // 8
    os.makedirs(base, exist_ok=True)

    rows = []
    for i in range(trials):
        print('tur %d/%d kosuyor...' % (i + 1, trials))
        rows.append(one_trial(base, n_row, n_rep, pkv))

    med = [statistics.median(r[i] for r in rows) for i in range(7)]
    b, a, ps, pk, cnt, op, size = med

    print()
    print('=== SQLite  N_ROWS=%d  N_REP=%d  tur=%d  (medyan) ==='
          % (n_row, n_rep, trials))
    print('dosya boyutu    : %d bayt  (%.1f B/satir)' % (size, size / n_row))
    print('toplu INSERT    : %8.0f ms  (%.3f us/satir)'
          % (b, b * 1000.0 / n_row))
    print('autocommit INS  : %8.0f ms  (%.3f ms/satir)' % (a, a / n_rep))
    print('parse-only SEL 1: %8.0f ms  (%.2f us/cagri)'
          % (ps, ps * 1000.0 / n_rep))
    print('PK nokta        : %8.0f ms  (%.2f us/sorgu)'
          % (pk, pk * 1000.0 / n_rep))
    print('COUNT(*)        : %8.0f ms' % cnt)
    print('acilis          : %8.0f ms' % op)
    print('sqlite %s | python %d-bit | synchronous=FULL'
          % (sqlite3.sqlite_version, 64 if sys.maxsize > 2 ** 32 else 32))


if __name__ == '__main__':
    main()
