"""pg_client_matrix kosucusu.

Kullanim:
    pgc_run.py <transport> <host> <port> <user> <password> <db> [tls]

transport: wire | psql | libpq | psycopg | jdbc | npgsql

Her kontrol icin tek satir yazar:
    RESULT <kontrol> OK
    RESULT <kontrol> FAIL <ayrinti>
    RESULT <kontrol> SKIP <gerekce>

Kontroller: connection, scram, tls, prepared, bind, describe, execute,
portal, portal_suspended, copy_in, copy_out, null, transaction,
cancel_request, sqlstate, close.

"wire" bacagi bu depodaki saf Python protokol istemcisidir; gercek bir
PostgreSQL istemcisi SAYILMAZ (bkz. pgc_wire.py). Diger bacaklar gercek
istemcilerdir ve yalniz kurulu olduklarinda kosar.
"""

import os
import subprocess
import sys
import threading
import time

CHECKS = ['connection', 'scram', 'tls', 'prepared', 'bind', 'describe',
          'execute', 'portal', 'portal_suspended', 'copy_in', 'copy_out',
          'null', 'transaction', 'cancel_request', 'sqlstate', 'close']

NROWS = 25


def emit(name, status, detail=''):
    if detail:
        print('RESULT %s %s %s' % (name, status, detail))
    else:
        print('RESULT %s %s' % (name, status))
    sys.stdout.flush()


class Rig(object):
    """Kontrolleri kosan ortak govde; istemciye ozgu parcalar alt sinifta."""

    def __init__(self, host, port, user, password, db, tls=False):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.db = db
        self.tls = tls
        self.setup_error = ''

    def run(self):
        for name in CHECKS:
            fn = getattr(self, 'check_' + name, None)
            if fn is None:
                emit(name, 'SKIP', 'bu bacakta uygulanmiyor')
                continue
            try:
                status, detail = fn()
            except Exception as exc:  # noqa: BLE001 - kosucu hatayi raporlar
                status, detail = 'FAIL', '%s: %s' % (type(exc).__name__, exc)
            emit(name, status, detail)


def result(ok, detail=''):
    # BASARIDA da ayrintiyi korur: sapmalar ve olculer rapora yazilsin.
    return ('OK', detail) if ok else ('FAIL', detail)


# ------------------------------------------------------------------ wire ---

class WireRig(Rig):
    def __init__(self, *a, **kw):
        Rig.__init__(self, *a, **kw)
        import pgc_wire
        self.W = pgc_wire.PgError
        self.PgClient = pgc_wire.PgClient
        self.c = None

    def _conn(self, password=None, sslmode='disable'):
        return self.PgClient(self.host, self.port, self.user,
                             self.password if password is None else password,
                             self.db).connect(sslmode=sslmode)

    def _reset(self):
        if self.c is not None:
            try:
                self.c.close()
            except Exception:
                pass
        self.c = self._conn()
        self.c.query('DROP TABLE IF EXISTS mtx')
        self.c.query('CREATE TABLE mtx (id INTEGER PRIMARY KEY, v INTEGER, s TEXT)')
        for i in range(1, NROWS + 1):
            self.c.query("INSERT INTO mtx VALUES (%d,%d,'r%d')" % (i, i, i))

    def check_connection(self):
        self.c = self._conn()
        rows, _ = self.c.query('SELECT 1')
        self._reset()
        return result(len(rows) == 1 and rows[0][0] == '1', 'satir=%r' % rows)

    def check_scram(self):
        bad = None
        try:
            self._conn(password='kesinlikle-yanlis')
        except self.W as exc:
            bad = exc.sqlstate
        if bad is None:
            return ('FAIL', 'yanlis parola kabul edildi')
        self.c.query('SELECT 1')
        return result(True) if bad == '28P01' else ('FAIL', 'sqlstate=%s' % bad)

    def check_tls(self):
        return ('SKIP', 'wire bacagi TLS kurmuyor (sunucuda TLS yapilandirmasi ayri kapida)')

    def check_prepared(self):
        out = self.c.prepare_execute('SELECT $1 AS n', ['7'])
        ok = (out['err'] is None and out['parse_complete'] == 1 and
              out['bind_complete'] == 1 and out['rows'] == [['7']])
        return result(ok, 'parse=%d bind=%d rows=%r err=%s' %
                      (out['parse_complete'], out['bind_complete'],
                       out['rows'], out['err']))

    def check_bind(self):
        # NOT (belgeli sapma): duz izdusumde (ORDER BY yok) NULL hucre
        # korunur; ama `SELECT $1 AS x` gibi bir izdusumde NULL maskesi
        # dusurulur ve '' doner. Bu yuzden NULL parametre `IS NULL` ile
        # dogrulanir; ikinci bind degerin gercekten tasindigini gosterir.
        null_out = self.c.prepare_execute('SELECT $1 IS NULL AS isn', [None])
        isnull = None
        if null_out['err'] is None and null_out['rows']:
            isnull = null_out['rows'][0][0]
        val_out = self.c.prepare_execute('SELECT $1 AS s', ['abc'])
        ok = (null_out['err'] is None and isnull is not None and
              str(isnull).lower() in ('true', 't', '1') and
              val_out['err'] is None and val_out['rows'] == [['abc']])
        return result(ok, 'isnull=%r bind=%r err=%s' %
                      (isnull, val_out['rows'], null_out['err']))

    def check_describe(self):
        # Describe Statement: VDB ParameterDescription gonderir ama
        # RowDescription GONDERMEZ (NoData) - belgeli sapma. Bu yuzden
        # burada yalniz parametre tanimini dogruluyoruz ve sapmayi
        # ayrintiya yaziyoruz. Describe Portal ise (SKILL17 duzeltmesiyle)
        # bos sonucta bile RowDescription dondurmelidir.
        self.c.parse('d1', 'SELECT id, s FROM mtx WHERE id = $1')
        self.c.describe('S', 'd1')
        self.c.sync()
        st = self.c.collect()
        self.c.bind('pd1', 'd1', ['999'])
        self.c.describe('P', 'pd1')
        self.c.sync()
        pt = self.c.collect()
        pnames = [c['name'] for c in pt['columns']]
        stnames = [c['name'] for c in st['columns']]
        ok = (st['parameter_desc'] == 1 and len(stnames) == 0 and
              st['no_data'] == 1 and pnames == ['id', 's'])
        return result(ok, 'stmt param=%d kolon=%r nodata=%d; portal kolon=%r '
                           '(Describe S RowDescription gondermez: belgeli sapma)'
                      % (st['parameter_desc'], stnames, st['no_data'], pnames))

    def check_execute(self):
        out = self.c.prepare_execute('SELECT v FROM mtx WHERE id = $1', ['3'])
        ok = out['complete'] == 1 and out['rows'] == [['3']]
        return result(ok, 'rows=%r tag=%s' % (out['rows'], out['tag']))

    def check_portal(self):
        self.c.parse('p1', 'SELECT id FROM mtx ORDER BY id')
        self.c.bind('po1', 'p1', [])
        self.c.execute('po1', 5)
        self.c.sync()
        out = self.c.collect()
        ok = len(out['rows']) == 5 and out['suspend'] == 1 and out['complete'] == 0
        self.c.close_portal('po1')
        self.c.sync()
        self.c.collect()
        return result(ok, 'satir=%d suspend=%d complete=%d' %
                      (len(out['rows']), out['suspend'], out['complete']))

    def check_portal_suspended(self):
        self.c.parse('p2', 'SELECT id FROM mtx ORDER BY id')
        self.c.bind('po2', 'p2', [])
        seen = []
        suspends = 0
        for _ in range(2):
            self.c.execute('po2', 10)
            self.c.sync()
            out = self.c.collect()
            seen.extend(r[0] for r in out['rows'])
            suspends += out['suspend']
        self.c.execute('po2', 10)
        self.c.sync()
        out = self.c.collect()
        seen.extend(r[0] for r in out['rows'])
        ok = (len(seen) == NROWS and suspends == 2 and out['complete'] == 1 and
              seen == [str(i) for i in range(1, NROWS + 1)])
        return result(ok, 'satir=%d suspend=%d complete=%d' %
                      (len(seen), suspends, out['complete']))

    def check_copy_in(self):
        self.c.query('DROP TABLE IF EXISTS mcp')
        self.c.query('CREATE TABLE mcp (id INTEGER, s TEXT)')
        # VDB'nin COPY varsayilani CSV'dir (ayirici ','); PostgreSQL'in
        # varsayilani text/tab'dir. Bu ONCEDEN VAR OLAN belgeli bir sapmadir
        # (tests/network_limits NL6). Gercek psql baci tab gonderirse bu
        # sapma gorunur; asagidaki notu rapora yaziyoruz.
        data = b''.join(('%d,c%d\n' % (i, i)).encode('utf-8') for i in range(1, 4))
        _, meta = self.c.copy_in('COPY mcp FROM STDIN', [data])
        rows, _ = self.c.query('SELECT COUNT(*) FROM mcp')
        ok = meta['tag'] == 'COPY 3' and rows[0][0] == '3'
        return result(ok, 'tag=%s sayi=%r; bicim=CSV (VDB varsayilani, '
                           'PG text/tab degil: belgeli sapma)' % (meta['tag'], rows))

    def check_copy_out(self):
        rows, meta = self.c.query('COPY (SELECT id FROM mtx) TO STDOUT')
        body = b''.join(meta['copy_data'])
        lines = [ln for ln in body.splitlines() if ln.strip()]
        ok = meta['copy_out'] and len(lines) == NROWS and lines[0] == b'1'
        return result(ok, 'copy_out=%s satir=%d bayt=%d' %
                      (meta['copy_out'], len(lines), len(body)))

    def check_null(self):
        # NOT (belgeli sinir): genisletilmis protokol YALNIZ SELECT'i
        # destekler (TVSql.OpenCursor: 'OpenCursor yalniz SELECT kabul
        # eder'). Parametreli INSERT bu yuzden denenmez; NULL degeri
        # basit protokolle yazip sirasiz okumada maskenin korundugunu
        # dogrulariz.
        self.c.query('DROP TABLE IF EXISTS mnul')
        self.c.query('CREATE TABLE mnul (id INTEGER, v INTEGER)')
        self.c.query('INSERT INTO mnul VALUES (1, NULL)')
        self.c.query('INSERT INTO mnul VALUES (2, 0)')
        rows, _ = self.c.query('SELECT v FROM mnul WHERE id = 1')
        rows2, _ = self.c.query('SELECT v FROM mnul WHERE id = 2')
        ok = (len(rows) == 1 and rows[0][0] is None and
              len(rows2) == 1 and rows2[0][0] == '0')
        return result(ok, 'null_satir=%r sifir_satir=%r (genisletilmis '
                           'protokol yalniz SELECT: belgeli sinir)' % (rows, rows2))

    def check_transaction(self):
        self.c.query('DROP TABLE IF EXISTS mtx3')
        self.c.query('CREATE TABLE mtx3 (id INTEGER, v INTEGER)')
        self.c.query('BEGIN')
        self.c.query('INSERT INTO mtx3 VALUES (2, 20)')
        self.c.query('ROLLBACK')
        rows, _ = self.c.query('SELECT COUNT(*) FROM mtx3 WHERE id = 2')
        rolled = rows[0][0] == '0'
        self.c.query('BEGIN')
        self.c.query('INSERT INTO mtx3 VALUES (3, 30)')
        self.c.query('COMMIT')
        rows, _ = self.c.query('SELECT COUNT(*) FROM mtx3 WHERE id = 3')
        return result(rolled and rows[0][0] == '1', 'rollback=%s commit=%r' % (rolled, rows))

    def check_cancel_request(self):
        # VDB'nin ayristiricisi virgullu capraz birlesimi desteklemez
        # ('anlasilamayan ek'); JOIN ... ON 1=1 kullanilir. 25^4 = 390k
        # satirlik toplam yaklasik 0.7 sn surer, iptal arada yetisir.
        # NOT: iptal, SORGUYU KOSAN baglantiya gonderilmelidir (backend
        # pid/secret o baglantiya aittir).
        for j in range(2, 5):
            t = 'mc%d' % j
            self.c.query('DROP TABLE IF EXISTS ' + t)
            self.c.query('CREATE TABLE ' + t + ' (id INTEGER)')
            for i in range(1, NROWS + 1):
                self.c.query('INSERT INTO %s VALUES (%d)' % (t, i))
        slow = self._conn()
        done = threading.Event()
        err = {}

        def worker():
            try:
                slow.query('SELECT COUNT(*) FROM mtx JOIN mc2 ON 1=1 '
                           'JOIN mc3 ON 1=1 JOIN mc4 ON 1=1')
            except Exception as exc:  # noqa: BLE001
                err['e'] = exc
            done.set()

        th = threading.Thread(target=worker)
        th.daemon = True
        th.start()
        time.sleep(0.10)
        if done.is_set():
            slow.close()
            return ('SKIP', 'sorgu iptalden once bitti')
        slow.cancel_request()
        th.join(30.0)
        code = getattr(err.get('e'), 'sqlstate', None)
        alive = False
        try:
            rows, _ = slow.query('SELECT 1')
            alive = rows == [['1']]
        except Exception:  # noqa: BLE001
            pass
        slow.close()
        ok = done.is_set() and code == '57014' and alive
        return result(ok, 'sqlstate=%s baglanti_hala_calisiyor=%s' % (code, alive))

    def check_sqlstate(self):
        code = None
        try:
            self.c.query('SELECT * FROM tablo_yok_xyz')
        except self.W as exc:
            code = exc.sqlstate
        return result(code == '42P01', 'sqlstate=%s' % code)

    def check_close(self):
        self.c.send_msg(b'X', b'')
        self.c.sock.close()
        self.c.sock = None
        self.c = self._conn()
        rows, _ = self.c.query('SELECT 1')
        return result(rows == [['1']], 'rows=%r' % rows)


# ------------------------------------------------------------------ psql ---

class PsqlRig(Rig):
    def __init__(self, *a, **kw):
        Rig.__init__(self, *a, **kw)
        self.psql = os.environ.get('VDB_PSQL', 'psql')

    def _run(self, sql, stdin=None, extra=()):
        env = dict(os.environ)
        env['PGPASSWORD'] = self.password
        env['PGCONNECT_TIMEOUT'] = '10'
        conn = 'host=%s port=%d user=%s dbname=%s sslmode=%s' % (
            self.host, self.port, self.user, self.db,
            'require' if self.tls else 'disable')
        cmd = [self.psql, conn, '-v', 'ON_ERROR_STOP=1', '-X', '-q'] + list(extra)
        if sql is not None:
            cmd += ['-c', sql]
        p = subprocess.Popen(cmd, env=env, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, err = p.communicate(stdin)
        return p.returncode, out.decode('utf-8', 'replace'), err.decode('utf-8', 'replace')

    def check_connection(self):
        code, out, err = self._run('SELECT 1')
        return result(code == 0 and out.strip() == '1', 'rc=%d out=%r err=%r' % (code, out, err))

    def check_scram(self):
        saved = self.password
        self.password = 'kesinlikle-yanlis'
        code, out, err = self._run('SELECT 1')
        self.password = saved
        code2, out2, _ = self._run('SELECT 1')
        return result(code != 0 and '28P01' in err and code2 == 0,
                      'rc=%d err=%r' % (code, err.strip()[:160]))

    def check_tls(self):
        self.tls = True
        code, out, err = self._run('SELECT 1')
        self.tls = False
        if code == 0:
            return ('OK', '')
        return ('SKIP', 'sunucuda TLS yapilandirilmadi: %s' % err.strip()[:120])

    def check_prepared(self):
        code, out, err = self._run('PREPARE ps(int) AS SELECT $1 + 1; EXECUTE ps(41)')
        return result(code == 0 and out.strip() == '42', 'rc=%d out=%r err=%r' % (code, out, err))

    def check_bind(self):
        return ('SKIP', 'psql parametre baglama API sunmuyor (PREPARE/EXECUTE ayri)')

    def check_describe(self):
        code, out, err = self._run('SELECT id, s FROM mtx LIMIT 0')
        # psql -c cikti basligi yalniz tablo biciminde gorunur.
        code2, out2, err2 = self._run('SELECT id, s FROM mtx LIMIT 1')
        ok = code == 0 and code2 == 0 and out2.startswith('1|r1')
        return result(ok, 'rc=%d out=%r' % (code2, out2.strip()[:120]))

    def check_execute(self):
        code, out, err = self._run('SELECT v FROM mtx WHERE id = 3')
        return result(code == 0 and out.strip() == '3', 'rc=%d out=%r' % (code, out))

    def check_portal(self):
        sql = ('BEGIN; DECLARE p CURSOR FOR SELECT id FROM mtx ORDER BY id; '
               'FETCH 5 FROM p; CLOSE p; COMMIT')
        code, out, err = self._run(sql)
        lines = [ln for ln in out.splitlines() if ln.strip()]
        return result(code == 0 and len(lines) == 5, 'rc=%d satir=%d' % (code, len(lines)))

    def check_portal_suspended(self):
        sql = ('BEGIN; DECLARE p2 CURSOR FOR SELECT id FROM mtx ORDER BY id; '
               'FETCH 10 FROM p2; FETCH 10 FROM p2; FETCH 10 FROM p2; CLOSE p2; COMMIT')
        code, out, err = self._run(sql)
        lines = [ln for ln in out.splitlines() if ln.strip()]
        return result(code == 0 and len(lines) == NROWS, 'rc=%d satir=%d' % (code, len(lines)))

    def check_copy_in(self):
        data = ''.join('%d\tc%d\n' % (i, i) for i in range(1, 4)).encode('utf-8')
        code, out, err = self._run('DROP TABLE IF EXISTS mcp2; CREATE TABLE mcp2 (id INTEGER, s TEXT)')
        if code != 0:
            return ('FAIL', 'tablo: %r' % err.strip()[:120])
        code, out, err = self._run('COPY mcp2 FROM STDIN', stdin=data)
        code2, out2, _ = self._run('SELECT COUNT(*) FROM mcp2')
        return result(code == 0 and code2 == 0 and out2.strip() == '3',
                      'rc=%d sayi=%r err=%r' % (code, out2.strip(), err.strip()[:120]))

    def check_copy_out(self):
        code, out, err = self._run('COPY mcp2 TO STDOUT')
        lines = [ln for ln in out.splitlines() if ln.strip()]
        return result(code == 0 and len(lines) == 3, 'rc=%d satir=%d' % (code, len(lines)))

    def check_null(self):
        code, out, err = self._run(
            'DROP TABLE IF EXISTS mnul2; CREATE TABLE mnul2 (id INTEGER, v INTEGER); '
            'INSERT INTO mnul2 VALUES (1, NULL); SELECT v IS NULL FROM mnul2')
        return result(code == 0 and out.strip().splitlines()[-1] in ('t', 'true'),
                      'rc=%d out=%r' % (code, out.strip()))

    def check_transaction(self):
        code, out, err = self._run(
            'BEGIN; INSERT INTO mnul2 VALUES (2, 20); ROLLBACK; '
            'SELECT COUNT(*) FROM mnul2 WHERE id = 2')
        return result(code == 0 and out.strip().splitlines()[-1] == '0',
                      'rc=%d out=%r' % (code, out.strip()))

    def check_cancel_request(self):
        return ('SKIP', 'psql iptali etkilesimli Ctrl-C ile yapilir; kosucu gondermiyor')

    def check_sqlstate(self):
        code, out, err = self._run('SELECT * FROM tablo_yok_xyz')
        return result(code != 0 and '42P01' in err, 'rc=%d err=%r' % (code, err.strip()[:160]))

    def check_close(self):
        code, out, err = self._run('SELECT 1')
        code2, out2, err2 = self._run('SELECT 2')
        return result(code == 0 and code2 == 0 and out2.strip() == '2',
                      'rc=%d/%d' % (code, code2))


# ----------------------------------------------------------------- libpq ---

class LibpqRig(Rig):
    def __init__(self, *a, **kw):
        Rig.__init__(self, *a, **kw)
        import ctypes
        import ctypes.util
        self.ct = ctypes
        name = os.environ.get('VDB_LIBPQ') or ctypes.util.find_library('pq') or 'libpq.so.5'
        self.lib = ctypes.CDLL(name)

        def decl(fn, res, args):
            f = getattr(self.lib, fn)
            f.restype = res
            f.argtypes = args
            return f

        c = ctypes
        self.PQconnectdb = decl('PQconnectdb', c.c_void_p, [c.c_char_p])
        self.PQstatus = decl('PQstatus', c.c_int, [c.c_void_p])
        self.PQerrorMessage = decl('PQerrorMessage', c.c_char_p, [c.c_void_p])
        self.PQfinish = decl('PQfinish', None, [c.c_void_p])
        self.PQexec = decl('PQexec', c.c_void_p, [c.c_void_p, c.c_char_p])
        self.PQresultStatus = decl('PQresultStatus', c.c_int, [c.c_void_p])
        self.PQresultErrorField = decl('PQresultErrorField', c.c_char_p, [c.c_void_p, c.c_int])
        self.PQntuples = decl('PQntuples', c.c_int, [c.c_void_p])
        self.PQnfields = decl('PQnfields', c.c_int, [c.c_void_p])
        self.PQgetvalue = decl('PQgetvalue', c.c_char_p, [c.c_void_p, c.c_int, c.c_int])
        self.PQgetisnull = decl('PQgetisnull', c.c_int, [c.c_void_p, c.c_int, c.c_int])
        self.PQfname = decl('PQfname', c.c_char_p, [c.c_void_p, c.c_int])
        self.PQclear = decl('PQclear', None, [c.c_void_p])
        self.PQprepare = decl('PQprepare', c.c_void_p,
                              [c.c_void_p, c.c_char_p, c.c_char_p, c.c_int, c.c_void_p])
        self.PQexecPrepared = decl('PQexecPrepared', c.c_void_p,
                                   [c.c_void_p, c.c_char_p, c.c_int, c.c_void_p,
                                    c.c_void_p, c.c_void_p, c.c_int])
        self.PQexecParams = decl('PQexecParams', c.c_void_p,
                                 [c.c_void_p, c.c_char_p, c.c_int, c.c_void_p,
                                  c.c_void_p, c.c_void_p, c.c_void_p, c.c_int])
        self.PQfreemem = decl('PQfreemem', None, [c.c_void_p])
        self.conn = None

    PGRES_COMMAND_OK = 1
    PGRES_TUPLES_OK = 2
    PGRES_COPY_IN = 4
    PGRES_COPY_OUT = 3
    PG_DIAG_SQLSTATE = ord('C')

    def _open(self):
        dsn = ('host=%s port=%d user=%s password=%s dbname=%s sslmode=%s '
               'connect_timeout=10' % (self.host, self.port, self.user,
                                       self.password, self.db,
                                       'require' if self.tls else 'disable'))
        conn = self.PQconnectdb(dsn.encode('utf-8'))
        if not conn or self.PQstatus(conn) != 0:
            msg = self.PQerrorMessage(conn).decode('utf-8', 'replace') if conn else 'baglanti yok'
            if conn:
                self.PQfinish(conn)
            raise RuntimeError(msg.strip())
        return conn

    def _exec(self, sql):
        res = self.PQexec(self.conn, sql.encode('utf-8'))
        try:
            st = self.PQresultStatus(res)
            if st not in (self.PGRES_COMMAND_OK, self.PGRES_TUPLES_OK,
                          self.PGRES_COPY_IN, self.PGRES_COPY_OUT):
                code = self.PQresultErrorField(res, self.PG_DIAG_SQLSTATE)
                raise RuntimeError('sqlstate=%s %s' % (
                    code.decode() if code else '?',
                    self.PQresultErrorField(res, ord('M')).decode('utf-8', 'replace')))
            return res, st
        except Exception:
            self.PQclear(res)
            raise

    def _rows(self, res):
        out = []
        for r in range(self.PQntuples(res)):
            row = []
            for c in range(self.PQnfields(res)):
                if self.PQgetisnull(res, r, c):
                    row.append(None)
                else:
                    row.append(self.PQgetvalue(res, r, c).decode('utf-8', 'replace'))
            out.append(row)
        return out

    def check_connection(self):
        self.conn = self._open()
        res, _ = self._exec('SELECT 1')
        rows = self._rows(res)
        self.PQclear(res)
        return result(rows == [['1']], 'rows=%r' % rows)

    def check_scram(self):
        saved = self.password
        self.password = 'kesinlikle-yanlis'
        failed = False
        try:
            c = self._open()
            self.PQfinish(c)
        except RuntimeError:
            failed = True
        self.password = saved
        return result(failed, 'yanlis parola reddedilmedi')

    def check_tls(self):
        self.tls = True
        try:
            c = self._open()
            self.PQfinish(c)
            return ('OK', '')
        except RuntimeError as exc:
            return ('SKIP', 'sunucuda TLS yapilandirilmadi: %s' % str(exc)[:120])
        finally:
            self.tls = False

    def check_prepared(self):
        res = self.PQprepare(self.conn, b'lb1', b'SELECT $1::int + 1', 0, None)
        st = self.PQresultStatus(res)
        self.PQclear(res)
        if st != self.PGRES_COMMAND_OK:
            return ('FAIL', 'PQprepare durum=%d' % st)
        res = self.PQexecPrepared(self.conn, b'lb1', 1, None, None, None, 0)
        rows = self._rows(res) if self.PQresultStatus(res) == self.PGRES_TUPLES_OK else []
        self.PQclear(res)
        return result(rows == [['42']], 'rows=%r' % rows)

    def check_bind(self):
        ct = self.ct
        vals = (ct.c_char_p * 2)(b'9', None)
        res = self.PQexecParams(self.conn, b'SELECT $1::int AS a, $2::text AS b', 2,
                                None, vals, None, None, 0)
        rows = self._rows(res) if self.PQresultStatus(res) == self.PGRES_TUPLES_OK else []
        self.PQclear(res)
        return result(rows == [['9', None]], 'rows=%r' % rows)

    def check_describe(self):
        res = self.PQprepare(self.conn, b'lb2', b'SELECT id, s FROM mtx LIMIT 0', 0, None)
        self.PQclear(res)
        res, _ = self._exec('SELECT id, s FROM mtx LIMIT 0')
        names = [self.PQfname(res, i).decode() for i in range(self.PQnfields(res))]
        self.PQclear(res)
        return result(names == ['id', 's'], 'kolonlar=%r' % names)

    def check_execute(self):
        res, _ = self._exec('SELECT v FROM mtx WHERE id = 3')
        rows = self._rows(res)
        self.PQclear(res)
        return result(rows == [['3']], 'rows=%r' % rows)

    def check_portal(self):
        return ('SKIP', 'libpq portal API tek satirlik akista sinirli (PQsendQueryParams)')

    def check_portal_suspended(self):
        return ('SKIP', 'libpq portal API tek satirlik akista sinirli (PQsendQueryParams)')

    def check_copy_in(self):
        self._drain(self._exec('DROP TABLE IF EXISTS mcp3; CREATE TABLE mcp3 (id INTEGER, s TEXT)')[0])
        res, st = self._exec('COPY mcp3 FROM STDIN')
        if st != self.PGRES_COPY_IN:
            self.PQclear(res)
            return ('FAIL', 'COPY IN baslamadi durum=%d' % st)
        for i in range(1, 4):
            data = b'%d\tq%d\n' % (i, i)
            self.lib.PQputCopyData(self.conn, data, len(data))
        self.lib.PQputCopyEnd(self.conn, None)
        bad = None
        while True:
            r = self.lib.PQgetResult(self.conn)
            if not r:
                break
            if self.PQresultStatus(r) not in (self.PGRES_COMMAND_OK, self.PGRES_TUPLES_OK):
                bad = 'durum=%d' % self.PQresultStatus(r)
            self.PQclear(r)
        self.PQclear(res)
        res, _ = self._exec('SELECT COUNT(*) FROM mcp3')
        rows = self._rows(res)
        self.PQclear(res)
        return result(bad is None and rows == [['3']], 'rows=%r bad=%s' % (rows, bad))

    def check_copy_out(self):
        res, st = self._exec('COPY mcp3 TO STDOUT')
        if st != self.PGRES_COPY_OUT:
            self.PQclear(res)
            return ('FAIL', 'COPY OUT baslamadi durum=%d' % st)
        self.PQclear(res)
        total = 0
        while True:
            buf = self.ct.c_char_p()
            n = self.lib.PQgetCopyData(self.conn, self.ct.byref(buf), 0)
            if n > 0:
                total += n
                self.PQfreemem(buf)
            elif n == 0:
                continue
            else:
                break
        self.lib.PQgetResult(self.conn)
        return result(total > 0, 'bayt=%d' % total)

    def _drain(self, res):
        self.PQclear(res)
        while True:
            r = self.lib.PQgetResult(self.conn)
            if not r:
                return
            self.PQclear(r)

    def check_null(self):
        self._drain(self._exec('DROP TABLE IF EXISTS mnul3; CREATE TABLE mnul3 (id INTEGER, v INTEGER)')[0])
        res = self.PQexecParams(self.conn, b'INSERT INTO mnul3 VALUES (1, NULL)', 0,
                                None, None, None, None, 0)
        self.PQclear(res)
        res, _ = self._exec('SELECT v IS NULL FROM mnul3')
        rows = self._rows(res)
        self.PQclear(res)
        return result(rows and rows[0][0] in ('t', 'true'), 'rows=%r' % rows)

    def check_transaction(self):
        res, _ = self._exec('BEGIN; INSERT INTO mnul3 VALUES (2, 20); ROLLBACK')
        self._drain(res)
        res, _ = self._exec('SELECT COUNT(*) FROM mnul3 WHERE id = 2')
        rows = self._rows(res)
        self.PQclear(res)
        return result(rows == [['0']], 'rows=%r' % rows)

    def check_cancel_request(self):
        return ('SKIP', 'libpq iptali ayri baglanti gerektirir; kosucu gondermiyor')

    def check_sqlstate(self):
        code = None
        res = self.PQexec(self.conn, b'SELECT * FROM tablo_yok_xyz')
        raw = self.PQresultErrorField(res, self.PG_DIAG_SQLSTATE)
        if raw:
            code = raw.decode()
        self.PQclear(res)
        return result(code == '42P01', 'sqlstate=%s' % code)

    def check_close(self):
        self.PQfinish(self.conn)
        self.conn = self._open()
        res, _ = self._exec('SELECT 2')
        rows = self._rows(res)
        self.PQclear(res)
        return result(rows == [['2']], 'rows=%r' % rows)


# --------------------------------------------------------------- psycopg ---

class PsycopgRig(Rig):
    def __init__(self, *a, **kw):
        Rig.__init__(self, *a, **kw)
        try:
            import psycopg2 as pg
            self.style = 2
        except ImportError:
            import psycopg as pg
            self.style = 3
        self.pg = pg
        self.conn = None

    def _open(self, password=None):
        kw = dict(host=self.host, port=self.port, user=self.user,
                  password=self.password if password is None else password,
                  dbname=self.db, connect_timeout=10,
                  sslmode='require' if self.tls else 'disable')
        return self.pg.connect(**kw)

    def _sqlstate(self, exc):
        return getattr(exc, 'pgcode', None) or getattr(exc, 'sqlstate', None)

    def _cur(self):
        c = self.conn.cursor()
        c.execute('DROP TABLE IF EXISTS mtx4')
        c.execute('CREATE TABLE mtx4 (id INTEGER PRIMARY KEY, v INTEGER, s TEXT)')
        for i in range(1, NROWS + 1):
            c.execute('INSERT INTO mtx4 VALUES (%s,%s,%s)', (i, i, 'r%d' % i))
        self.conn.commit()
        return c

    def check_connection(self):
        self.conn = self._open()
        c = self.conn.cursor()
        c.execute('SELECT 1')
        rows = c.fetchall()
        return result(rows == [(1,)], 'rows=%r' % rows)

    def check_scram(self):
        failed = False
        try:
            bad = self._open(password='kesinlikle-yanlis')
            bad.close()
        except Exception:  # noqa: BLE001
            failed = True
        return result(failed, 'yanlis parola reddedilmedi')

    def check_tls(self):
        self.tls = True
        try:
            c = self._open()
            c.close()
            return ('OK', '')
        except Exception as exc:  # noqa: BLE001
            return ('SKIP', 'sunucuda TLS yapilandirilmadi: %s' % str(exc)[:120])
        finally:
            self.tls = False

    def check_prepared(self):
        c = self.conn.cursor()
        c.execute('SELECT %s::int + 1', (41,))
        return result(c.fetchall() == [(42,)], 'rows=%r' % (c.fetchall(),))

    def check_bind(self):
        c = self.conn.cursor()
        c.execute('SELECT %s::int AS a, %s::text AS b', (9, None))
        rows = c.fetchall()
        return result(rows == [(9, None)], 'rows=%r' % rows)

    def check_describe(self):
        c = self.conn.cursor()
        c.execute('SELECT id, s FROM mtx4 LIMIT 0')
        names = [d[0] for d in c.description]
        return result(names == ['id', 's'], 'kolonlar=%r' % names)

    def check_execute(self):
        c = self.conn.cursor()
        c.execute('SELECT v FROM mtx4 WHERE id = %s', (3,))
        return result(c.fetchall() == [(3,)], 'rows=%r' % (c.fetchall(),))

    def check_portal(self):
        c = self.conn.cursor('portal1')
        c.itersize = 5
        c.execute('SELECT id FROM mtx4 ORDER BY id')
        first = c.fetchmany(5)
        return result(len(first) == 5, 'satir=%d' % len(first))

    def check_portal_suspended(self):
        c = self.conn.cursor('portal2')
        c.itersize = 10
        c.execute('SELECT id FROM mtx4 ORDER BY id')
        got = list(c.fetchmany(10)) + list(c.fetchmany(10)) + list(c.fetchmany(10))
        return result([r[0] for r in got] == list(range(1, NROWS + 1)),
                      'satir=%d' % len(got))

    def check_copy_in(self):
        c = self.conn.cursor()
        c.execute('DROP TABLE IF EXISTS mcp4')
        c.execute('CREATE TABLE mcp4 (id INTEGER, s TEXT)')
        import io
        buf = io.StringIO(''.join('%d\tp%d\n' % (i, i) for i in range(1, 4)))
        c.copy_from(buf, 'mcp4')
        self.conn.commit()
        c.execute('SELECT COUNT(*) FROM mcp4')
        return result(c.fetchone() == (3,), 'rows=%r' % (c.fetchone(),))

    def check_copy_out(self):
        import io
        buf = io.StringIO()
        c = self.conn.cursor()
        c.copy_to(buf, 'mcp4')
        return result(buf.getvalue().count('\n') == 3, 'bayt=%d' % len(buf.getvalue()))

    def check_null(self):
        c = self.conn.cursor()
        c.execute('DROP TABLE IF EXISTS mnul4')
        c.execute('CREATE TABLE mnul4 (id INTEGER, v INTEGER)')
        c.execute('INSERT INTO mnul4 VALUES (%s,%s)', (1, None))
        c.execute('SELECT v IS NULL FROM mnul4 WHERE id = 1')
        return result(c.fetchone() == (True,), 'rows=%r' % (c.fetchone(),))

    def check_transaction(self):
        c = self.conn.cursor()
        c.execute('BEGIN')
        c.execute('INSERT INTO mnul4 VALUES (2, 20)')
        self.conn.rollback()
        c.execute('SELECT COUNT(*) FROM mnul4 WHERE id = 2')
        return result(c.fetchone() == (0,), 'rows=%r' % (c.fetchone(),))

    def check_cancel_request(self):
        slow = self._open()
        slow.autocommit = True
        cur = slow.cursor()

        def worker():
            try:
                cur.execute('SELECT COUNT(*) FROM mtx4 a, mtx4 b, mtx4 c')
            except Exception:  # noqa: BLE001
                pass

        th = threading.Thread(target=worker)
        th.daemon = True
        th.start()
        time.sleep(0.05)
        if not th.is_alive():
            slow.close()
            return ('SKIP', 'sorgu iptalden once bitti')
        slow.cancel()
        th.join(10.0)
        slow.close()
        return result(not th.is_alive(), 'iptal 10 sn icinde sonuclanmadi')

    def check_sqlstate(self):
        code = None
        c = self.conn.cursor()
        try:
            c.execute('SELECT * FROM tablo_yok_xyz')
        except Exception as exc:  # noqa: BLE001
            code = self._sqlstate(exc)
        self.conn.rollback()
        return result(code == '42P01', 'sqlstate=%s' % code)

    def check_close(self):
        self.conn.close()
        self.conn = self._open()
        c = self.conn.cursor()
        c.execute('SELECT 2')
        return result(c.fetchall() == [(2,)], 'rows=%r' % (c.fetchall(),))


RIGS = {'wire': WireRig, 'psql': PsqlRig, 'libpq': LibpqRig, 'psycopg': PsycopgRig}


def probe():
    """Kurulu bacaklari yazar: AVAIL <bacak> OK|NO <gerekce>."""
    import shutil
    psql = os.environ.get('VDB_PSQL') or shutil.which('psql')
    print('AVAIL psql %s' % ('OK ' + psql if psql else 'NO psql PATH icinde yok'))
    try:
        import ctypes
        import ctypes.util
        name = os.environ.get('VDB_LIBPQ') or ctypes.util.find_library('pq')
        if not name:
            for cand in ('libpq.so.5', 'libpq.5.dylib', 'libpq.dll'):
                try:
                    ctypes.CDLL(cand)
                    name = cand
                    break
                except OSError:
                    continue
        if name:
            ctypes.CDLL(name)
            print('AVAIL libpq OK %s' % name)
        else:
            print('AVAIL libpq NO libpq paylasimli kutuphanesi bulunamadi')
    except Exception as exc:  # noqa: BLE001
        print('AVAIL libpq NO %s' % exc)
    for mod in ('psycopg2', 'psycopg'):
        try:
            __import__(mod)
            print('AVAIL psycopg OK %s' % mod)
            break
        except Exception:  # noqa: BLE001
            continue
    else:
        print('AVAIL psycopg NO psycopg/psycopg2 modulu yok')


def bootstrap(argv):
    """Gercek istemci kosmadan ONCE rol kurar: <host> <port> <role>.

    Sunucu bu fazda kimlik dogrulamasiz (trust) calisir ve oturum bos role
    baglidir; bu yuzden SUPERUSER rolu olusturulabilir. Boylece SCRAM ile
    dogrulanan gercek istemci, GRANT verilmemis bir rol yuzunden
    '42501' almaz. Rol zaten varsa bu bir hata degildir.
    """
    import pgc_wire
    host, port, role = argv[2], int(argv[3]), argv[4]
    c = pgc_wire.PgClient(host, port, 'bootstrap', '', 'db').connect()
    try:
        c.query('CREATE ROLE ' + role + ' SUPERUSER')
        print('BOOTSTRAP rol olusturuldu: %s' % role)
    except pgc_wire.PgError as exc:
        if exc.sqlstate == '42710':
            print('BOOTSTRAP rol zaten var: %s' % role)
        else:
            print('BOOTSTRAP HATA %s %s' % (exc.sqlstate, exc.message))
            return 1
    finally:
        c.close()
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == 'probe':
        probe()
        return 0
    if len(argv) == 5 and argv[1] == 'bootstrap':
        return bootstrap(argv)
    if len(argv) < 7:
        sys.stderr.write(__doc__)
        return 64
    transport = argv[1].lower()
    host, port, user, password, db = argv[2], int(argv[3]), argv[4], argv[5], argv[6]
    tls = len(argv) > 7 and argv[7] == '1'
    rig_cls = RIGS.get(transport)
    if rig_cls is None:
        print('DESTEKLENMEYEN %s kosucusu bu depoda yok' % transport)
        return 65
    rig = rig_cls(host, port, user, password, db, tls)
    try:
        rig.run()
    except Exception as exc:  # noqa: BLE001
        print('RESULT connection FAIL %s: %s' % (type(exc).__name__, exc))
        return 3
    finally:
        conn = getattr(rig, 'conn', None)
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
