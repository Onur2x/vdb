"""Saf Python PostgreSQL wire istemcisi (yalniz standart kutuphane).

Bu modul GERCEK bir PostgreSQL istemcisi DEGILDIR: sunucunun wire
protokolunu kendi elimizle konusur. pg_client_matrix kapisinda yalniz
"wire" bacagi olarak, gercek istemcilerin bulunmadigi makinelerde
protokolun kendisinin bozulmadigini gostermek icin kullanilir. Gercek
istemci bacaklari (psql, libpq, psycopg, JDBC, Npgsql) ayri kosucularla
denenir; hicbiri yoksa kapi Halt(77) ile SKIP verir.
"""

import hashlib
import hmac
import socket
import struct

SSL_REQUEST = 80877103
CANCEL_REQUEST = 80877102


class PgError(Exception):
    def __init__(self, sqlstate, message, severity='ERROR'):
        Exception.__init__(self, '%s %s' % (sqlstate, message))
        self.sqlstate = sqlstate
        self.message = message
        self.severity = severity


class PgClient(object):
    def __init__(self, host, port, user, password, database, timeout=15.0):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.sock = None
        self.backend_pid = 0
        self.backend_secret = 0
        self.params = {}
        self.tls = False
        self.timeout = timeout

    # ---- alt duzey ----
    def _send(self, data):
        self.sock.sendall(data)

    def _recv_exact(self, n):
        buf = b''
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise IOError('baglanti kapandi')
            buf += chunk
        return buf

    def send_msg(self, typ, body):
        self._send(typ + struct.pack('!I', len(body) + 4) + body)

    def recv_msg(self):
        typ = self._recv_exact(1)
        ln = struct.unpack('!I', self._recv_exact(4))[0]
        if ln < 4 or ln > 64 * 1024 * 1024:
            raise IOError('gecersiz mesaj uzunlugu: %d' % ln)
        body = self._recv_exact(ln - 4)
        return typ, body

    @staticmethod
    def _cstr(body, off):
        end = body.index(b'\x00', off)
        return body[off:end].decode('utf-8', 'replace'), end + 1

    def _read_error(self, body):
        fields = {}
        off = 0
        while off < len(body) and body[off] != 0:
            code = chr(body[off])
            val, off = self._cstr(body, off + 1)
            fields[code] = val
        return PgError(fields.get('C', 'XX000'), fields.get('M', ''),
                       fields.get('S', 'ERROR'))

    # ---- baglanti ----
    def connect(self, sslmode='disable', appname='vdb-matrix-wire'):
        self.sock = socket.create_connection((self.host, self.port), self.timeout)
        self.sock.settimeout(self.timeout)
        if sslmode != 'disable':
            self._send(struct.pack('!II', 8, SSL_REQUEST))
            ans = self._recv_exact(1)
            if ans == b'S':
                raise PgError('08004', 'TLS istemci tarafi bu betikte yok')
            if sslmode == 'require':
                raise PgError('08004', 'sunucu TLS sunmuyor')
        params = ('user\x00' + self.user + '\x00'
                  'database\x00' + self.database + '\x00'
                  'application_name\x00' + appname + '\x00'
                  'client_encoding\x00UTF8\x00\x00')
        head = struct.pack('!II', len(params) + 8, 196608)
        self._send(head + params.encode('utf-8'))
        return self._auth_loop()

    def _auth_loop(self):
        scram = None
        while True:
            typ, body = self.recv_msg()
            if typ == b'R':
                code = struct.unpack('!I', body[:4])[0]
                if code == 0:
                    continue
                if code == 3:
                    self.send_msg(b'p', self.password.encode('utf-8') + b'\x00')
                    continue
                if code == 10:
                    mechs = body[4:].split(b'\x00')
                    if b'SCRAM-SHA-256' not in mechs:
                        raise PgError('28000', 'SCRAM-SHA-256 onerilmedi')
                    scram = _Scram(self.password)
                    first = scram.client_first()
                    # SASLInitialResponse: mekanizma adi (NUL) + Int32 + veri
                    body = b'SCRAM-SHA-256\x00' + struct.pack('!I', len(first)) + first
                    self._send(b'p' + struct.pack('!I', len(body) + 4) + body)
                    continue
                if code == 11:
                    if scram is None:
                        raise PgError('28000', 'beklenmeyen SASLContinue')
                    final = scram.client_final(body[4:])
                    self._send(b'p' + struct.pack('!I', len(final) + 4) + final)
                    continue
                if code == 12:
                    if scram is None or not scram.verify_server(body[4:]):
                        raise PgError('28000', 'sunucu imzasi dogrulanamadi')
                    continue
                raise PgError('28000', 'desteklenmeyen kimlik dogrulama: %d' % code)
            if typ == b'S':
                key, _ = self._cstr(body, 0)
                val, _ = self._cstr(body, len(key) + 1)
                self.params[key] = val
                continue
            if typ == b'K':
                self.backend_pid, self.backend_secret = struct.unpack('!II', body[:8])
                continue
            if typ == b'E':
                raise self._read_error(body)
            if typ == b'Z':
                return self
            if typ == b'N':
                continue
            raise PgError('08P01', 'startup sirasinda beklenmeyen mesaj: %r' % typ)

    # ---- basit sorgu ----
    def query(self, sql, maxrows=0):
        """Basit sorgu: DataRow metinleri listesi + komut etiketi doner."""
        rows, meta = self._run_simple(sql.encode('utf-8') + b'\x00')
        return rows, meta

    def _run_simple(self, body):
        self.send_msg(b'Q', body)
        rows = []
        meta = {'tag': '', 'copy_in': False, 'copy_out': False, 'copy_data': [],
                'notices': [], 'columns': []}
        err = None
        while True:
            typ, mb = self.recv_msg()
            if typ == b'T':
                meta['columns'] = _row_desc(mb)
            elif typ == b'D':
                rows.append(_data_row(mb))
            elif typ == b'C':
                meta['tag'] = mb[:-1].decode('utf-8', 'replace')
            elif typ == b'E':
                # Hata yanitindan sonra ReadyForQuery gelir; onu OKUMADAN
                # cikmak akisi bir cumle kaydirir (sonraki sorgu bos doner).
                err = self._read_error(mb)
            elif typ == b'N':
                meta['notices'].append(mb.decode('utf-8', 'replace'))
            elif typ == b'G':
                meta['copy_in'] = True
                return rows, meta
            elif typ == b'H':
                meta['copy_out'] = True
            elif typ == b'd':
                meta['copy_data'].append(mb)
            elif typ == b'c':
                continue
            elif typ == b'Z':
                if err is not None:
                    raise err
                return rows, meta
            elif typ in (b'S', b'I', b'K'):
                continue
            else:
                raise PgError('08P01', 'beklenmeyen mesaj: %r' % typ)

    def copy_in(self, sql, chunks):
        rows, meta = self.query(sql)
        if not meta['copy_in']:
            raise PgError('08P01', 'COPY IN baslamadi')
        for ch in chunks:
            self.send_msg(b'd', ch)
        self.send_msg(b'c', b'')
        rows, meta = self._drain_after_copy()
        return rows, meta

    def _drain_after_copy(self):
        rows = []
        meta = {'tag': '', 'columns': []}
        err = None
        while True:
            typ, mb = self.recv_msg()
            if typ == b'C':
                meta['tag'] = mb[:-1].decode('utf-8', 'replace')
            elif typ == b'E':
                err = self._read_error(mb)
            elif typ == b'Z':
                if err is not None:
                    raise err
                return rows, meta
            elif typ == b'D':
                rows.append(_data_row(mb))

    # ---- genisletilmis protokol ----
    def parse(self, name, sql, param_types=()):
        body = name.encode('utf-8') + b'\x00' + sql.encode('utf-8') + b'\x00'
        body += struct.pack('!H', len(param_types))
        for t in param_types:
            body += struct.pack('!I', t)
        self.send_msg(b'P', body)

    def bind(self, portal, stmt, params, result_formats=()):
        body = portal.encode('utf-8') + b'\x00' + stmt.encode('utf-8') + b'\x00'
        body += struct.pack('!H', 0)  # tum parametreler metin
        body += struct.pack('!H', len(params))
        for p in params:
            if p is None:
                body += struct.pack('!i', -1)
            else:
                raw = p.encode('utf-8') if isinstance(p, str) else p
                body += struct.pack('!i', len(raw)) + raw
        body += struct.pack('!H', len(result_formats))
        for f in result_formats:
            body += struct.pack('!H', f)
        self.send_msg(b'B', body)

    def describe(self, kind, name):
        self.send_msg(b'D', kind.encode('utf-8') + name.encode('utf-8') + b'\x00')

    def execute(self, portal, maxrows=0):
        self.send_msg(b'E', portal.encode('utf-8') + b'\x00' + struct.pack('!I', maxrows))

    def sync(self):
        self.send_msg(b'S', b'')

    def close_portal(self, name):
        self.send_msg(b'C', b'P' + name.encode('utf-8') + b'\x00')

    def collect(self):
        """Sync sonrasi: DataRow listesi + olay sayaclari doner."""
        out = {'rows': [], 'columns': [], 'suspend': 0, 'complete': 0,
               'tag': '', 'err': None, 'parse_complete': 0, 'bind_complete': 0,
               'no_data': 0, 'close_complete': 0, 'parameter_desc': 0}
        while True:
            typ, mb = self.recv_msg()
            if typ == b'1':
                out['parse_complete'] += 1
            elif typ == b'2':
                out['bind_complete'] += 1
            elif typ == b'3':
                out['close_complete'] += 1
            elif typ == b't':
                out['parameter_desc'] += 1
            elif typ == b'T':
                out['columns'] = _row_desc(mb)
            elif typ == b'n':
                out['no_data'] += 1
            elif typ == b'D':
                out['rows'].append(_data_row(mb))
            elif typ == b's':
                out['suspend'] += 1
            elif typ == b'C':
                out['complete'] += 1
                out['tag'] = mb[:-1].decode('utf-8', 'replace')
            elif typ == b'E':
                out['err'] = self._read_error(mb)
            elif typ == b'Z':
                return out
            elif typ in (b'S', b'I', b'N'):
                continue
            elif typ == b'G':
                out['copy_in'] = True
                return out
            else:
                raise PgError('08P01', 'beklenmeyen mesaj: %r' % typ)

    def prepare_execute(self, sql, params=(), maxrows=0, chunked=0):
        """Parse+Bind+Describe+Execute+Sync; chunked>0 ise portal parcalanir."""
        self.parse('', sql)
        self.bind('', '', params)
        self.describe('P', '')
        self.execute('', maxrows)
        self.sync()
        return self.collect()

    # ---- iptal ----
    def cancel_request(self):
        s = socket.create_connection((self.host, self.port), self.timeout)
        try:
            s.sendall(struct.pack('!IIII', 16, CANCEL_REQUEST,
                                  self.backend_pid, self.backend_secret))
            s.settimeout(1.0)
            try:
                s.recv(1)
            except socket.timeout:
                pass
        finally:
            s.close()

    def close(self):
        if self.sock is not None:
            try:
                self.send_msg(b'X', b'')
            except Exception:
                pass
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None


def _row_desc(body):
    n = struct.unpack('!H', body[:2])[0]
    cols = []
    off = 2
    for _ in range(n):
        end = body.index(b'\x00', off)
        name = body[off:end].decode('utf-8', 'replace')
        off = end + 1
        tableoid, colno, typoid, typlen, typmod, fmt = struct.unpack('!IHIhih', body[off:off + 18])
        off += 18
        cols.append({'name': name, 'type': typoid, 'format': fmt, 'tableoid': tableoid,
                     'colno': colno, 'typlen': typlen, 'typmod': typmod})
    return cols


def _data_row(body):
    n = struct.unpack('!H', body[:2])[0]
    vals = []
    off = 2
    for _ in range(n):
        ln = struct.unpack('!i', body[off:off + 4])[0]
        off += 4
        if ln < 0:
            vals.append(None)
        else:
            vals.append(body[off:off + ln].decode('utf-8', 'replace'))
            off += ln
    return vals


class _Scram(object):
    def __init__(self, password):
        self.password = password.encode('utf-8')
        self.nonce = hashlib.sha256(b'vdb-matrix').hexdigest()[:24]
        self.first_bare = 'n=,r=' + self.nonce
        self.server_first = ''
        self.salted = b''

    def client_first(self):
        msg = ('n,,' + self.first_bare).encode('utf-8')
        return msg

    def client_final(self, server_first):
        self.server_first = server_first.decode('utf-8')
        parts = dict(p.split('=', 1) for p in self.server_first.split(','))
        salt = _unb64(parts['s'])
        iters = int(parts['i'])
        self.salted = hashlib.pbkdf2_hmac('sha256', self.password, salt, iters)
        client_key = hmac.new(self.salted, b'Client Key', hashlib.sha256).digest()
        stored_key = hashlib.sha256(client_key).digest()
        without_proof = 'c=biws,r=' + parts['r']
        auth_msg = (self.first_bare + ',' + self.server_first + ',' +
                    without_proof).encode('utf-8')
        sig = hmac.new(stored_key, auth_msg, hashlib.sha256).digest()
        proof = bytes(a ^ b for a, b in zip(client_key, sig))
        server_key = hmac.new(self.salted, b'Server Key', hashlib.sha256).digest()
        self.server_sig = hmac.new(server_key, auth_msg, hashlib.sha256).digest()
        return (without_proof + ',p=' + _b64(proof)).encode('utf-8')

    def verify_server(self, body):
        text = body.decode('utf-8')
        parts = dict(p.split('=', 1) for p in text.split(','))
        return parts.get('v') == _b64(self.server_sig)


def _b64(data):
    import base64
    return base64.b64encode(data).decode('ascii')


def _unb64(text):
    import base64
    return base64.b64decode(text)
