#!/usr/bin/env python3
# SKILL17: SQLite bacagi, olcekli benchmark.
# bench_scale.lpr ile AYNI is yuku, AYNI veri kumesi, AYNI islem siniri.
# Bagimsiz SQLite (Python stdlib sqlite3); harici DLL/bagimlilik yok.
# Cikti: <path>.out (anahtar=deger) ve <path>.csv (faz istatistikleri).
#
# Olcum birimi mikrosaniyedir (time.perf_counter). P50/P95/P99 tek tek
# islemlerin ya da tekrar kosularin dagilimindan hesaplanir; her satir
# kac islemin olculdugunu "ops" alaninda yazar. Hicbir hiz iddiasi kurmaz.
import os
import sys
import time
import sqlite3

BATCH = 100
DIM = 100
READ_REPS = 500
SCAN_REPS = 20
TX_REPS = 50


def pct(vals, p):
    if not vals:
        return 0
    s = sorted(vals)
    if len(s) == 1:
        return int(s[0])
    idx = int(round((len(s) - 1) * p / 100.0))
    if idx < 0:
        idx = 0
    if idx >= len(s):
        idx = len(s) - 1
    return int(s[idx])


def main():
    if len(sys.argv) < 3:
        print('kullanim: sqlite_scale.py <db yolu> <N> [FULL|NORMAL|OFF]')
        return 2
    path = sys.argv[1]
    n = int(sys.argv[2])
    sync = (sys.argv[3] if len(sys.argv) > 3 else 'NORMAL').upper()
    if sync not in ('FULL', 'NORMAL', 'OFF'):
        print('gecersiz synchronous: %s (FULL/NORMAL/OFF)' % sync)
        return 2
    if n < 1000:
        print('N cok kucuk')
        return 2
    if os.path.exists(path):
        os.remove(path)
    for suffix in ('-wal', '-shm'):
        if os.path.exists(path + suffix):
            os.remove(path + suffix)

    point_id = n // 2
    range_lo = n // 5
    range_hi = range_lo + 999
    keep = n - 500

    out = []
    rows = []

    def emit(k, v):
        out.append('%s=%s' % (k, v))

    def phase(name, ops, vals_us):
        total = int(sum(vals_us))
        rows.append((name, ops, total, pct(vals_us, 50), pct(vals_us, 95), pct(vals_us, 99)))

    con = sqlite3.connect(path)
    cur = con.cursor()
    # Esit kosullar (SKILL18): SQLite tarafinin durability ayari disaridan
    # secilir (varsayilan NORMAL) ve raporda ADIYLA yazilir. Esdeger profiller:
    # (VDB DurableOnFlush=1, synchronous=FULL) tam dayaniklilik;
    # (VDB DurableOnFlush=0, synchronous=NORMAL) dengeli.
    journal = cur.execute('PRAGMA journal_mode=WAL').fetchone()[0]
    cur.execute('PRAGMA synchronous=' + sync)
    syn = cur.execute('PRAGMA synchronous').fetchone()[0]
    emit('JOURNAL_MODE', journal)
    emit('SYNCHRONOUS', syn)
    emit('SYNCHRONOUS_NAME', sync)

    t = time.perf_counter()
    cur.execute('CREATE TABLE bench (id INTEGER PRIMARY KEY, grp INTEGER, val INTEGER, txt TEXT)')
    cur.execute('CREATE TABLE dim (id INTEGER PRIMARY KEY, name TEXT)')
    cur.executemany('INSERT INTO dim VALUES (?,?)', [(i, 'd%d' % i) for i in range(DIM)])
    con.commit()
    phase('schema', 1, [int((time.perf_counter() - t) * 1e6)])

    t = time.perf_counter()
    for base in range(0, n, BATCH):
        stop = min(base + BATCH, n)
        batch = [(i, i % 10, i, 'row-%d' % i) for i in range(base, stop)]
        q = ','.join(['(?,?,?,?)'] * len(batch))
        cur.execute('INSERT INTO bench VALUES ' + q,
                    [v for row in batch for v in row])
    con.commit()
    phase('bulk_insert', n, [int((time.perf_counter() - t) * 1e6)])
    emit('COUNT_INSERT', cur.execute('SELECT COUNT(*) FROM bench').fetchone()[0])

    # Tek satir INSERT: her biri kendi isleminde (durability ayni).
    vals = []
    single_base = n
    for k in range(200):
        t = time.perf_counter()
        cur.execute('BEGIN')
        cur.execute('INSERT INTO bench VALUES (?,?,?,?)',
                    (single_base + k, k % 10, single_base + k, 'single-%d' % k))
        con.commit()
        vals.append(int((time.perf_counter() - t) * 1e6))
    phase('single_insert', len(vals), vals)
    emit('SINGLE_INSERTED', 200)

    t = time.perf_counter()
    cur.execute('CREATE INDEX ix_bench_grp ON bench(grp)')
    con.commit()
    phase('index_secondary', 1, [int((time.perf_counter() - t) * 1e6)])

    t = time.perf_counter()
    cur.execute('CREATE INDEX ix_bench_val_grp ON bench(val, grp)')
    con.commit()
    phase('index_composite', 1, [int((time.perf_counter() - t) * 1e6)])

    vals = []
    point = None
    for _ in range(READ_REPS):
        t = time.perf_counter()
        r = cur.execute('SELECT val FROM bench WHERE id = ?', (point_id,)).fetchone()
        vals.append(int((time.perf_counter() - t) * 1e6))
        point = r[0]
    phase('point_lookup', len(vals), vals)
    emit('POINT', point)

    vals = []
    rc = rs = 0
    for _ in range(SCAN_REPS):
        t = time.perf_counter()
        r = cur.execute('SELECT COUNT(*), SUM(val) FROM bench WHERE id BETWEEN ? AND ?',
                        (range_lo, range_hi)).fetchone()
        vals.append(int((time.perf_counter() - t) * 1e6))
        rc, rs = r[0], r[1]
    phase('range_scan', len(vals), vals)
    emit('RANGE_COUNT', rc)
    emit('RANGE_SUM', rs)

    t = time.perf_counter()
    g = cur.execute('SELECT grp, COUNT(*), SUM(val) FROM bench GROUP BY grp ORDER BY grp').fetchall()
    phase('group_by', 1, [int((time.perf_counter() - t) * 1e6)])
    emit('GROUP_ROWS', len(g))
    emit('GROUP_SUM', sum(x[2] for x in g))
    emit('GROUP_COUNT_SUM', sum(x[1] for x in g))

    t = time.perf_counter()
    r = cur.execute('SELECT COUNT(*) FROM bench b JOIN dim d ON b.grp = d.id WHERE d.id < 50').fetchone()
    phase('join', 1, [int((time.perf_counter() - t) * 1e6)])
    emit('JOIN_ROWS', r[0])

    t = time.perf_counter()
    r = cur.execute('SELECT val FROM bench ORDER BY val DESC').fetchall()
    phase('order_by', len(r), [int((time.perf_counter() - t) * 1e6)])
    emit('ORDER_ROWS', len(r))
    emit('ORDER_FIRST', r[0][0])
    emit('ORDER_LAST', r[-1][0])

    t = time.perf_counter()
    r = cur.execute('SELECT DISTINCT grp FROM bench ORDER BY grp').fetchall()
    phase('distinct', len(r), [int((time.perf_counter() - t) * 1e6)])
    emit('DISTINCT_ROWS', len(r))

    # Buyuk sonuc akisi: satirlar tek tek cekilir (tum kume bellekte tutulmaz).
    t = time.perf_counter()
    streamed = 0
    for _ in cur.execute('SELECT id, val FROM bench'):
        streamed += 1
    phase('result_stream', streamed, [int((time.perf_counter() - t) * 1e6)])
    emit('STREAM_ROWS', streamed)

    vals = []
    for k in range(TX_REPS):
        t = time.perf_counter()
        cur.execute('BEGIN')
        cur.execute('UPDATE bench SET val = val + 1 WHERE id = ?', (k,))
        con.commit()
        vals.append(int((time.perf_counter() - t) * 1e6))
    phase('tx_commit', len(vals), vals)

    vals = []
    for k in range(TX_REPS):
        t = time.perf_counter()
        cur.execute('BEGIN')
        cur.execute('UPDATE bench SET val = val + 1 WHERE id = ?', (k,))
        con.rollback()
        vals.append(int((time.perf_counter() - t) * 1e6))
    phase('tx_rollback', len(vals), vals)

    t = time.perf_counter()
    cur.execute('BEGIN')
    cur.execute('UPDATE bench SET val = val + 1 WHERE grp = 2')
    con.commit()
    phase('update', 1, [int((time.perf_counter() - t) * 1e6)])

    t = time.perf_counter()
    r = cur.execute('SELECT COUNT(*), SUM(val) FROM bench').fetchone()
    phase('scan', 1, [int((time.perf_counter() - t) * 1e6)])
    emit('COUNT_AFTER_UPDATE', r[0])
    emit('SUM_AFTER_UPDATE', r[1])

    t = time.perf_counter()
    cur.execute('BEGIN')
    cur.execute('DELETE FROM bench WHERE id >= ?', (keep,))
    con.commit()
    phase('delete', 1, [int((time.perf_counter() - t) * 1e6)])

    r = cur.execute('SELECT COUNT(*), SUM(val) FROM bench').fetchone()
    emit('COUNT_AFTER_DELETE', r[0])
    emit('SUM_AFTER_DELETE', r[1])

    cur.close()
    con.close()

    # Yedek/geri yukleme: SQLite bagimsiz arac gerektirmeden dosya kopyasi.
    import shutil
    bk = path + '.bak'
    t = time.perf_counter()
    shutil.copyfile(path, bk)
    phase('backup', 1, [int((time.perf_counter() - t) * 1e6)])
    emit('BACKUP_BYTES', os.path.getsize(bk))

    t = time.perf_counter()
    shutil.copyfile(bk, path)
    phase('restore', 1, [int((time.perf_counter() - t) * 1e6)])

    # Yeniden acilis: kapanmis dosyanin acilma suresi ve satir sayisi.
    t = time.perf_counter()
    con = sqlite3.connect(path)
    cur = con.cursor()
    recover_rows = cur.execute('SELECT COUNT(*) FROM bench').fetchone()[0]
    phase('recovery_open', 1, [int((time.perf_counter() - t) * 1e6)])
    emit('RECOVER_ROWS', recover_rows)
    cur.close()
    con.close()

    emit('DB_BYTES', os.path.getsize(path))
    wal = path + '-wal'
    emit('WAL_BYTES', os.path.getsize(wal) if os.path.exists(wal) else 0)

    # Bellek: Linux'ta resource, Windows'ta psapi; ikisi de yoksa 0 kalir.
    peak = 0
    try:
        import resource
        peak = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
        if sys.platform != 'darwin':
            peak *= 1024  # Linux KiB -> bayt
    except Exception:
        peak = 0
    if peak == 0 and sys.platform == 'win32':
        try:
            import ctypes
            from ctypes import wintypes

            class PMC(ctypes.Structure):
                _fields_ = [
                    ('cb', wintypes.DWORD),
                    ('PageFaultCount', wintypes.DWORD),
                    ('PeakWorkingSetSize', ctypes.c_size_t),
                    ('WorkingSetSize', ctypes.c_size_t),
                    ('QuotaPeakPagedPoolUsage', ctypes.c_size_t),
                    ('QuotaPagedPoolUsage', ctypes.c_size_t),
                    ('QuotaPeakNonPagedPoolUsage', ctypes.c_size_t),
                    ('QuotaNonPagedPoolUsage', ctypes.c_size_t),
                    ('PagefileUsage', ctypes.c_size_t),
                    ('PeakPagefileUsage', ctypes.c_size_t),
                ]

            m = PMC()
            m.cb = ctypes.sizeof(m)
            k32 = ctypes.windll.kernel32
            psapi = ctypes.windll.psapi
            k32.GetCurrentProcess.restype = wintypes.HANDLE
            psapi.GetProcessMemoryInfo.argtypes = [
                wintypes.HANDLE, ctypes.POINTER(PMC), wintypes.DWORD]
            psapi.GetProcessMemoryInfo.restype = wintypes.BOOL
            h = k32.GetCurrentProcess()
            if psapi.GetProcessMemoryInfo(h, ctypes.byref(m), m.cb):
                peak = int(m.PeakWorkingSetSize)
        except Exception:
            peak = 0
    emit('PEAK_RSS_BYTES', peak)

    with open(path + '.out', 'w', encoding='ascii') as f:
        f.write('ENGINE=sqlite\n')
        f.write('N=%d\n' % n)
        for line in out:
            f.write(line + '\n')

    with open(path + '.csv', 'w', encoding='ascii', newline='\n') as f:
        f.write('engine,size,phase,ops,total_us,p50_us,p95_us,p99_us\n')
        for (name, ops, total, p50, p95, p99) in rows:
            f.write('sqlite,%d,%s,%d,%d,%d,%d,%d\n' % (n, name, ops, total, p50, p95, p99))

    print('OK sqlite n=%d' % n)
    return 0


sys.exit(main())
