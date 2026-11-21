#!/usr/bin/env python3
# SKILL6 08 (D): SQLite tarafi. VDB tarafiyla AYNI is yuku, AYNI veri kumesi,
# AYNI islem sayisi. Bagimsiz SQLite (Python stdlib sqlite3).
# Cikti: anahtar=deger satirlari. Hicbir performans iddiasi kurmaz.
import sys, os, time, sqlite3

N = 5000
BATCH = 100
DIM = 100


def ms(t0):
    return int(round((time.perf_counter() - t0) * 1000.0))


def main():
    if len(sys.argv) != 2:
        print('kullanim hatasi')
        return 2
    path = sys.argv[1]
    if os.path.exists(path):
        os.remove(path)
    out = []
    def emit(k, v):
        out.append('%s=%s' % (k, v))

    emit('ENGINE', 'sqlite')
    emit('SQLITE_VERSION', sqlite3.sqlite_version)
    emit('N', N)

    con = sqlite3.connect(path)
    cur = con.cursor()
    jm = cur.execute('PRAGMA journal_mode=WAL').fetchone()[0]
    cur.execute('PRAGMA synchronous=NORMAL')
    syn = cur.execute('PRAGMA synchronous').fetchone()[0]
    emit('JOURNAL_MODE', jm)
    emit('SYNCHRONOUS', syn)

    t = time.perf_counter()
    cur.execute('CREATE TABLE bench (id INTEGER PRIMARY KEY, grp INTEGER, val INTEGER, txt TEXT)')
    cur.execute('CREATE TABLE dim (id INTEGER PRIMARY KEY, name TEXT)')
    cur.executemany('INSERT INTO dim VALUES (?,?)',
                    [(i, 'd%d' % i) for i in range(DIM)])
    con.commit()
    emit('MS_SCHEMA', ms(t))

    t = time.perf_counter()
    cur.execute('BEGIN')
    for base in range(0, N, BATCH):
        rows = [(i, i % 10, i, 'row-%d' % i) for i in range(base, base + BATCH)]
        cur.executemany('INSERT INTO bench VALUES (?,?,?,?)', rows)
    con.commit()
    emit('MS_INSERT', ms(t))
    emit('COUNT_INSERT', cur.execute('SELECT COUNT(*) FROM bench').fetchone()[0])

    t = time.perf_counter()
    cur.execute('CREATE INDEX ix_bench_grp ON bench(grp)')
    con.commit()
    emit('MS_INDEX', ms(t))

    t = time.perf_counter()
    point = None
    for _ in range(1000):
        r = cur.execute('SELECT val FROM bench WHERE id = 2500').fetchone()
        point = r[0]
    emit('MS_POINT', ms(t))
    emit('POINT', point)

    t = time.perf_counter()
    rc = rs = 0
    for _ in range(50):
        r = cur.execute('SELECT COUNT(*), SUM(val) FROM bench WHERE id BETWEEN 1000 AND 1999').fetchone()
        rc, rs = r[0], r[1]
    emit('MS_RANGE', ms(t))
    emit('RANGE_COUNT', rc)
    emit('RANGE_SUM', rs)

    t = time.perf_counter()
    g = cur.execute('SELECT grp, COUNT(*), SUM(val) FROM bench GROUP BY grp ORDER BY grp').fetchall()
    emit('MS_GROUP', ms(t))
    emit('GROUP_ROWS', len(g))
    emit('GROUP_SUM', sum(x[2] for x in g))
    emit('GROUP_COUNT_SUM', sum(x[1] for x in g))

    t = time.perf_counter()
    r = cur.execute('SELECT COUNT(*) FROM bench b JOIN dim d ON b.grp = d.id WHERE d.id < 50').fetchone()
    emit('MS_JOIN', ms(t))
    emit('JOIN_ROWS', r[0])

    t = time.perf_counter()
    cur.execute('BEGIN')
    cur.execute('UPDATE bench SET val = val + 1 WHERE grp = 2')
    con.commit()
    emit('MS_UPDATE', ms(t))

    t = time.perf_counter()
    r = cur.execute('SELECT COUNT(*), SUM(val) FROM bench').fetchone()
    emit('MS_SCAN', ms(t))
    emit('COUNT_AFTER_UPDATE', r[0])
    emit('SUM_AFTER_UPDATE', r[1])

    t = time.perf_counter()
    cur.execute('BEGIN')
    cur.execute('DELETE FROM bench WHERE id > 4499')
    con.commit()
    emit('MS_DELETE', ms(t))

    r = cur.execute('SELECT COUNT(*), SUM(val) FROM bench').fetchone()
    emit('COUNT_AFTER_DELETE', r[0])
    emit('SUM_AFTER_DELETE', r[1])

    cur.close()
    con.close()
    emit('DB_BYTES', os.path.getsize(path))
    wal = path + '-wal'
    emit('WAL_BYTES', os.path.getsize(wal) if os.path.exists(wal) else 0)

    f = open(sys.argv[1] + '.out', 'w', encoding='ascii')
    for line in out:
        f.write(line + '\n')
    f.close()
    print('OK sqlite')
    return 0


sys.exit(main())
