"""Independent (pyarrow) side of tests/interop_external.

Modes
  selftest            -> import pyarrow, print version
  check <file> arrow  -> VDB'in yazdigi Arrow IPC stream'i dogrular
  check <file> parquet-> VDB'in yazdigi Parquet'i dogrular
  gen <dir>           -> pyarrow ile harici Arrow/Parquet dosyalari uretir
  checkcells <file> arrow|parquet
                      -> tipli export'ta NULL ile bos metin/ikili AYRIMINI
                         dogrular (SKILL13)
  gennulls <dir>      -> NULL/bos ayrimi tasiyan harici dosyalari uretir
  genbig <dir>        -> cok batch'li buyuk Arrow stream'i
  genbigparquet <dir> -> cok row group'lu buyuk Parquet dosyasi
  checkdec <file> arrow|parquet
                      -> VDB'nin yazdigi DECIMAL(12,3)'u precision/scale
                         ve TAM deger ile dogrular (SKILL14)
  gendec <dir>        -> pyarrow ile harici DECIMAL(10,2) dosyalari uretir
  checkcodec <file> <codec> <grup> <satir>
                      -> VDB'nin yazdigi Parquet'in codec, satir grubu ve
                         degerlerini dogrular (SKILL15)
  gencodec <dir>      -> pyarrow ile SNAPPY ve ZSTD Parquet dosyalari uretir

Exit 0 = tum dogrulamalar gecti. Exit 2 = dogrulama basarisiz (ayrinti stdout).
Bu betik yalniz TEST tarafidir; depoya yeni bir calisma-zamani bagimliligi
eklemez ve VDB'nin uretim kodu bu betige bagli degildir.
"""
import datetime
import decimal
import os
import sys

EXIT_BAD = 2


def load_pyarrow():
    try:
        import pyarrow  # noqa: F401
    except ImportError:
        extra = os.environ.get("VDB_PY_LIBS")
        if not extra:
            raise
        sys.path.insert(0, extra)
        import pyarrow  # noqa: F401
    import pyarrow as pa
    import pyarrow.parquet as pq
    return pa, pq


# Pascal tarafi interop_external.lpr icinde AYNI 4 satiri yazar.
VDB_ROWS = [
    {"id": 42, "score": 2.5, "name": "hello", "ok": True,
     "born": datetime.date(2026, 11, 21),
     "seen": datetime.datetime(2026, 11, 21, 13, 45, 7),
     "at": datetime.time(13, 45, 7), "blob": b"ABC"},
    {"id": -7, "score": -0.25, "name": "merhaba dunya", "ok": False,
     "born": datetime.date(1970, 1, 1),
     "seen": datetime.datetime(2000, 1, 1, 0, 0, 0),
     "at": datetime.time(0, 0, 0), "blob": None},
    # VDB'de '' hucresi NULL olarak yazilir (durust sinir, SKILL6 03/04).
    {"id": 0, "score": 0.0, "name": None, "ok": True,
     "born": datetime.date(2024, 2, 29),
     "seen": datetime.datetime(1999, 12, 31, 23, 59, 59),
     "at": datetime.time(23, 59, 59), "blob": b"x"},
    {"id": 2147483647, "score": 123456.75, "name": "satir 4", "ok": False,
     "born": datetime.date(2038, 1, 19),
     "seen": datetime.datetime(2038, 1, 19, 3, 14, 8),
     "at": datetime.time(23, 59, 59), "blob": b"binary"},
]

EXPECTED_FAMS = [
    ("id", "int"), ("score", "float"), ("name", "string"), ("ok", "bool"),
    ("born", "date"), ("seen", "timestamp"), ("at", "time"), ("blob", "binary"),
]


def fam(typ):
    s = str(typ)
    if s.startswith("int") or s.startswith("uint"):
        return "int"
    if s.startswith("double") or s.startswith("float"):
        return "float"
    if s.startswith("string") or s.startswith("large_string"):
        return "string"
    if s.startswith("bool"):
        return "bool"
    if s.startswith("date"):
        return "date"
    if s.startswith("timestamp"):
        return "timestamp"
    if s.startswith("time"):
        return "time"
    if s.startswith("binary") or s.startswith("large_binary"):
        return "binary"
    return s


def read_table(path, kind, pa, pq):
    if kind == "parquet":
        return pq.read_table(path)
    with open(path, "rb") as fh:
        return pa.ipc.open_stream(fh).read_all()


def check(path, kind):
    pa, pq = load_pyarrow()
    if not os.path.exists(path):
        print(f"FAIL dosya yok: {path}")
        return EXIT_BAD
    try:
        table = read_table(path, kind, pa, pq)
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL {kind} okunamadi: {exc}")
        return EXIT_BAD

    names = list(table.schema.names)
    fams = [fam(f.type) for f in table.schema]
    want_names = [n for n, _ in EXPECTED_FAMS]
    want_fams = [f for _, f in EXPECTED_FAMS]
    if names != want_names:
        print(f"FAIL alan adlari: {names} != {want_names}")
        return EXIT_BAD
    if fams != want_fams:
        print(f"FAIL alan tipleri: {list(zip(names, fams))} != {list(zip(want_names, want_fams))}")
        return EXIT_BAD

    rows = table.to_pylist()
    if len(rows) != len(VDB_ROWS):
        print(f"FAIL satir sayisi {len(rows)} != {len(VDB_ROWS)}")
        return EXIT_BAD
    for i, (got, want) in enumerate(zip(rows, VDB_ROWS)):
        for key, w in want.items():
            g = got[key]
            if isinstance(w, float):
                good = g is not None and abs(float(g) - w) <= 1e-12
            elif isinstance(w, datetime.datetime):
                good = g == w
            elif isinstance(w, datetime.time):
                good = g is not None and g.hour == w.hour and g.minute == w.minute \
                    and g.second == w.second
            else:
                good = g == w
            if not good:
                print(f"FAIL satir {i} alan {key}: {g!r} != {w!r}")
                return EXIT_BAD

    if kind == "parquet":
        pf = pq.ParquetFile(path)
        print(f"OK parquet satir={len(rows)} row_groups={pf.num_row_groups} "
              f"codec={pf.metadata.row_group(0).column(0).compression}")
    else:
        print(f"OK arrow satir={len(rows)} tip={[str(f.type) for f in table.schema]}")
    return 0


# SKILL13: tipli hucre (TVdbCellMatrix) kapsami. Pascal tarafi
# interop_external.lpr icinde AYNI 4 satiri YAZAR ve AYNI dosyalari OKUR.
# row0: bos metin ve bos ikili GERCEK deger (NULL DEGIL).
# row1: dort alan da NULL.
# row3: metin NULL ama ikili bos (NULL'den ayri).
CELL_ROWS = [
    {"id": 1, "name": "", "blob": b"", "score": 1.5, "ok": True},
    {"id": 2, "name": None, "blob": None, "score": None, "ok": None},
    {"id": 3, "name": "x", "blob": b"AB", "score": 2.0, "ok": False},
    {"id": 4, "name": None, "blob": b"", "score": 0.0, "ok": True},
]

CELL_FAMS = [("id", "int"), ("name", "string"), ("blob", "binary"),
             ("score", "float"), ("ok", "bool")]

# Alan basina beklenen NULL sayisi (id NULL tasimaz).
CELL_NULLS = {"id": 0, "name": 2, "blob": 1, "score": 1, "ok": 1}


def checkcells(path, kind):
    """Tipli export: NULL ile bos metin/ikili AYRI olmali (SKILL13)."""
    pa, pq = load_pyarrow()
    if not os.path.exists(path):
        print(f"FAIL dosya yok: {path}")
        return EXIT_BAD
    try:
        table = read_table(path, kind, pa, pq)
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL {kind} okunamadi: {exc}")
        return EXIT_BAD

    names = list(table.schema.names)
    want_names = [n for n, _ in CELL_FAMS]
    if names != want_names:
        print(f"FAIL tipli alan adlari: {names} != {want_names}")
        return EXIT_BAD
    fams = [fam(f.type) for f in table.schema]
    want_fams = [f for _, f in CELL_FAMS]
    if fams != want_fams:
        print(f"FAIL tipli alan tipleri: {list(zip(names, fams))}")
        return EXIT_BAD

    for key, want in CELL_NULLS.items():
        got = table.column(key).null_count
        if got != want:
            print(f"FAIL NULL sayisi {key}: {got} != {want}")
            return EXIT_BAD

    rows = table.to_pylist()
    if len(rows) != len(CELL_ROWS):
        print(f"FAIL tipli satir sayisi {len(rows)} != {len(CELL_ROWS)}")
        return EXIT_BAD
    for i, (got, want) in enumerate(zip(rows, CELL_ROWS)):
        for key, w in want.items():
            g = got[key]
            if isinstance(w, float):
                good = g is not None and abs(float(g) - w) <= 1e-12
            elif w is None:
                good = g is None
            elif isinstance(w, bytes):
                # Bos ikili gercekten bos ikili olmali, NULL degil.
                good = isinstance(g, (bytes, bytearray)) and bytes(g) == w
            else:
                good = g == w
            if not good:
                print(f"FAIL tipli satir {i} alan {key}: {g!r} != {w!r}")
                return EXIT_BAD

    # Acik ayrim kaniti: bos metin/bos ikili NULL SAYILMAZ.
    if rows[0]["name"] != "" or rows[0]["blob"] != b"":
        print("FAIL bos metin/ikili NULL olarak yazilmis")
        return EXIT_BAD
    if kind == "parquet":
        pf = pq.ParquetFile(path)
        print(f"OK cells parquet satir={len(rows)} rg={pf.num_row_groups} nulls="
              f"{[table.column(n).null_count for n in want_names]}")
    else:
        print(f"OK cells arrow satir={len(rows)} nulls="
              f"{[table.column(n).null_count for n in want_names]}")
    return 0


EXT_ROWS = [
    dict(id=i, name=(None if i == 4 else ("''" if i == 5 else f"n-{i}")),
         score=i / 2.0, ok=(i % 2 == 0),
         born=datetime.date(2026, 3, 1) + datetime.timedelta(days=i),
         seen=datetime.datetime(2026, 3, 1, 12, 0, 0) + datetime.timedelta(seconds=i),
         at=datetime.time(12, 0, i),
         blob=(None if i == 3 else b"x%d" % i))
    for i in range(6)
]
# Row 5 name: gercek bos metin ('' -> pyarrow'da bos string, NULL DEGIL).
EXT_ROWS[5]["name"] = ""


def gen(outdir):
    pa, pq = load_pyarrow()
    if not os.path.isdir(outdir):
        os.makedirs(outdir)
    ids = [r["id"] for r in EXT_ROWS]
    scores = [r["score"] for r in EXT_ROWS]
    names = [r["name"] for r in EXT_ROWS]
    oks = [r["ok"] for r in EXT_ROWS]
    born = [r["born"] for r in EXT_ROWS]
    seen = [r["seen"] for r in EXT_ROWS]
    ats = [r["at"] for r in EXT_ROWS]
    blobs = [r["blob"] for r in EXT_ROWS]
    table = pa.table({
        "id": pa.array(ids, pa.int64()),
        "score": pa.array(scores, pa.float64()),
        "name": pa.array(names, pa.string()),
        "ok": pa.array(oks, pa.bool_()),
        "born": pa.array(born, pa.date32()),
        "seen": pa.array(seen, pa.timestamp("ms")),
        "at": pa.array(ats, pa.time32("ms")),
        "blob": pa.array(blobs, pa.binary()),
    })
    a = os.path.join(outdir, "ext_vdb.arrow")
    p = os.path.join(outdir, "ext_vdb.parquet")
    s = os.path.join(outdir, "ext_vdb_snappy.parquet")
    with pa.OSFile(a, "wb") as sink:
        with pa.ipc.new_stream(sink, table.schema) as writer:
            writer.write_table(table.slice(0, 3))
            writer.write_table(table.slice(3, 3))
    pq.write_table(table, p, compression="NONE", row_group_size=2)
    pq.write_table(table, s, compression="snappy", row_group_size=2)

    # Birim (unit) kapsami: Arrow semasinda Date.unit ve Time.unit varsayilani
    # MILLISECOND'dur; pyarrow varsayilana esit birimi tabloya YAZMAZ. Bu
    # yuzden time32[ms] ve date64[ms] "birimsiz" tablo olarak gelir. VDB'nin
    # varsayilani dogru okumasi X8 ile kilitlenir (SKILL6 08 defecti).
    u = pa.table({
        "d64": pa.array([datetime.date(2026, 3, 1)] * 3, pa.date64()),
        "t32s": pa.array([datetime.time(12, 0, i) for i in range(3)],
                         pa.time32("s")),
        "t32ms": pa.array([datetime.time(12, 0, i) for i in range(3)],
                          pa.time32("ms")),
        "t64us": pa.array([datetime.time(12, 0, i) for i in range(3)],
                          pa.time64("us")),
        "t64ns": pa.array([datetime.time(12, 0, i) for i in range(3)],
                          pa.time64("ns")),
    })
    uf = os.path.join(outdir, "ext_vdb_units.arrow")
    with pa.OSFile(uf, "wb") as sink:
        with pa.ipc.new_stream(sink, u.schema) as writer:
            writer.write_table(u)

    for f in (a, p, s, uf):
        print(f"GEN {os.path.basename(f)} {os.path.getsize(f)}")
    return 0


def gennulls(outdir):
    """Tipli kapsam: NULL / bos metin / bos ikili ayrimi tasiyan dosyalar.

    Arrow 2 batch (2+2 satir), Parquet row_group_size=2 -> 2 row group.
    """
    pa, pq = load_pyarrow()
    if not os.path.isdir(outdir):
        os.makedirs(outdir)
    table = pa.table({
        "id": pa.array([r["id"] for r in CELL_ROWS], pa.int32()),
        "name": pa.array([r["name"] for r in CELL_ROWS], pa.string()),
        "blob": pa.array([r["blob"] for r in CELL_ROWS], pa.binary()),
        "score": pa.array([r["score"] for r in CELL_ROWS], pa.float64()),
        "ok": pa.array([r["ok"] for r in CELL_ROWS], pa.bool_()),
    })
    a = os.path.join(outdir, "ext_nulls.arrow")
    p = os.path.join(outdir, "ext_nulls.parquet")
    with pa.OSFile(a, "wb") as sink:
        with pa.ipc.new_stream(sink, table.schema) as writer:
            writer.write_table(table.slice(0, 2))
            writer.write_table(table.slice(2, 2))
    pq.write_table(table, p, compression="NONE", row_group_size=2)
    for f in (a, p):
        print(f"GEN {os.path.basename(f)} {os.path.getsize(f)}")
    return 0


def genbig(outdir, batches=40, rows=250):
    """Cok batch'li buyuk Arrow stream: batch bazli okuma kaniti (spec E)."""
    pa, _ = load_pyarrow()
    if not os.path.isdir(outdir):
        os.makedirs(outdir)
    schema = pa.schema([("id", pa.int32()), ("name", pa.string())])
    path = os.path.join(outdir, "ext_big.arrow")
    with pa.OSFile(path, "wb") as sink:
        with pa.ipc.new_stream(sink, schema) as writer:
            for b in range(batches):
                base = b * rows
                tbl = pa.table({
                    "id": pa.array(list(range(base, base + rows)), pa.int32()),
                    "name": pa.array([f"r{i}" for i in range(base, base + rows)],
                                     pa.string()),
                })
                writer.write_table(tbl)
    print(f"GEN {os.path.basename(path)} {os.path.getsize(path)} "
          f"batches={batches} rows={rows}")
    return 0


def genbigparquet(outdir, groups=50, rows=200):
    """Cok row group'lu buyuk Parquet: grup bazli okuma kaniti (spec E)."""
    pa, pq = load_pyarrow()
    if not os.path.isdir(outdir):
        os.makedirs(outdir)
    n = groups * rows
    tbl = pa.table({
        "id": pa.array(list(range(n)), pa.int32()),
        "name": pa.array([f"r{i}" for i in range(n)], pa.string()),
    })
    path = os.path.join(outdir, "ext_big.parquet")
    pq.write_table(tbl, path, compression="NONE", row_group_size=rows)
    print(f"GEN {os.path.basename(path)} {os.path.getsize(path)} "
          f"groups={groups} rows={rows}")
    return 0


# SKILL14: DECIMAL(12,3) tipli kapsam. Pascal tarafi AYNI 5 satiri
# VDbArrowExportCellsEx / VDbParquetExportCellsEx ile yazar; burada
# pyarrow semayi (precision, scale) ve degerleri FLOAT'A CEVMEDEN dogrular.
DEC_PREC = 12
DEC_SCALE = 3
DEC_ROWS = [
    {"id": 1, "v": decimal.Decimal("123.456")},
    {"id": 2, "v": decimal.Decimal("-0.001")},
    {"id": 3, "v": decimal.Decimal("0.000")},
    {"id": 4, "v": decimal.Decimal("999999999.999")},
    {"id": 5, "v": None},
]

# pyarrow'un kendisi tarafindan yazilan harici DECIMAL(10,2). Pascal tarafi
# bunu VDB ile okur ve AYNI kanonik metinleri bekler (None = NULL).
GEN_DEC_PREC = 10
GEN_DEC_SCALE = 2
GEN_DEC_ROWS = [
    {"id": 1, "v": decimal.Decimal("12.34")},
    {"id": 2, "v": decimal.Decimal("-0.05")},
    {"id": 3, "v": decimal.Decimal("0.00")},
    {"id": 4, "v": None},
    {"id": 5, "v": decimal.Decimal("-99999999.99")},
]


def checkdec(path, kind):
    """VDB'nin yazdigi DECIMAL(12,3) kolonunu pyarrow ile dogrular."""
    pa, pq = load_pyarrow()
    if not os.path.exists(path):
        print(f"FAIL dosya yok: {path}")
        return EXIT_BAD
    try:
        table = read_table(path, kind, pa, pq)
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL {kind} dec okunamadi: {exc}")
        return EXIT_BAD

    names = list(table.schema.names)
    if names != ["id", "v"]:
        print(f"FAIL dec alan adlari: {names} != ['id', 'v']")
        return EXIT_BAD
    vt = table.schema.field("v").type
    if not pa.types.is_decimal(vt):
        print(f"FAIL dec tipi DECIMAL degil: {vt}")
        return EXIT_BAD
    if vt.precision != DEC_PREC or vt.scale != DEC_SCALE:
        print(f"FAIL dec (p,s): ({vt.precision},{vt.scale}) != "
              f"({DEC_PREC},{DEC_SCALE})")
        return EXIT_BAD
    nulls = table.column("v").null_count
    want_nulls = sum(1 for r in DEC_ROWS if r["v"] is None)
    if nulls != want_nulls:
        print(f"FAIL dec NULL sayisi {nulls} != {want_nulls}")
        return EXIT_BAD

    rows = table.to_pylist()
    if len(rows) != len(DEC_ROWS):
        print(f"FAIL dec satir sayisi {len(rows)} != {len(DEC_ROWS)}")
        return EXIT_BAD
    for i, (got, want) in enumerate(zip(rows, DEC_ROWS)):
        if got["id"] != want["id"]:
            print(f"FAIL dec satir {i} id: {got['id']!r} != {want['id']!r}")
            return EXIT_BAD
        g = got["v"]
        w = want["v"]
        if w is None:
            good = g is None
        else:
            # decimal.Decimal uzerinden TAM karsilastirma (float yuvarlama yok).
            good = g is not None and decimal.Decimal(g) == w
        if not good:
            print(f"FAIL dec satir {i} v: {g!r} != {w!r}")
            return EXIT_BAD

    if kind == "parquet":
        pf = pq.ParquetFile(path)
        col = pf.metadata.row_group(0).column(1)
        print(f"OK dec parquet satir={len(rows)} p={vt.precision} "
              f"s={vt.scale} fiziksel={col.physical_type} "
              f"nulls={nulls} rg={pf.num_row_groups}")
    else:
        print(f"OK dec arrow satir={len(rows)} p={vt.precision} "
              f"s={vt.scale} nulls={nulls}")
    return 0


def gendec(outdir):
    """pyarrow ile harici DECIMAL(10,2) Arrow ve Parquet dosyalari uretir."""
    pa, pq = load_pyarrow()
    if not os.path.isdir(outdir):
        os.makedirs(outdir)
    typ = pa.decimal128(GEN_DEC_PREC, GEN_DEC_SCALE)
    tbl = pa.table({
        "id": pa.array([r["id"] for r in GEN_DEC_ROWS], pa.int32()),
        "v": pa.array([r["v"] for r in GEN_DEC_ROWS], typ),
    })
    apath = os.path.join(outdir, "ext_dec.arrow")
    with pa.ipc.new_stream(apath, tbl.schema) as wr:
        wr.write_table(tbl)
    ppath = os.path.join(outdir, "ext_dec.parquet")
    pq.write_table(tbl, ppath, compression="NONE")
    print(f"GEN ext_dec.arrow {os.path.getsize(apath)} p={GEN_DEC_PREC} "
          f"s={GEN_DEC_SCALE}")
    pf = pq.ParquetFile(ppath)
    print(f"GEN ext_dec.parquet {os.path.getsize(ppath)} "
          f"fiziksel={pf.metadata.row_group(0).column(1).physical_type}")
    return 0


def codec_rows(n):
    """X13/X17 icin beklenen satirlar: id 1..n, v = id/1000 (olcek 3), s = 'r<id>'.

    Her 50. satir tamamen NULL'dur; iki taraf da ayni kurali uygular.
    """
    rows = []
    for i in range(1, n + 1):
        if i % 50 == 0:
            rows.append({"id": None, "v": None, "s": None})
        else:
            rows.append({"id": i,
                         "v": decimal.Decimal(i) / decimal.Decimal(1000),
                         "s": "r%d" % i})
    return rows


def checkcodec(path, want_codec, want_groups, want_rows):
    """VDB'nin yazdigi Parquet dosyasini codec, satir grubu ve deger ile dogrular."""
    pa, pq = load_pyarrow()
    pf = pq.ParquetFile(path)
    md = pf.metadata
    want = want_codec.upper()
    got_groups = md.num_row_groups
    if got_groups != want_groups:
        print(f"FAIL codec satir grubu {got_groups} != {want_groups}")
        return EXIT_BAD
    for g in range(got_groups):
        rg = md.row_group(g)
        for c in range(rg.num_columns):
            comp = rg.column(c).compression
            if comp.upper() != want:
                print(f"FAIL codec grup {g} kolon {c}: {comp} != {want}")
                return EXIT_BAD
    if md.num_rows != want_rows:
        print(f"FAIL codec satir sayisi {md.num_rows} != {want_rows}")
        return EXIT_BAD
    table = pf.read()
    names = table.schema.names
    if names != ["id", "v", "s"]:
        print(f"FAIL codec kolonlar {names}")
        return EXIT_BAD
    vt = table.schema.field("v").type
    if not pa.types.is_decimal(vt) or vt.precision != 12 or vt.scale != 3:
        print(f"FAIL codec v tipi {vt}")
        return EXIT_BAD
    got = table.to_pylist()
    wantr = codec_rows(want_rows)
    if len(got) != len(wantr):
        print(f"FAIL codec okunan satir {len(got)} != {len(wantr)}")
        return EXIT_BAD
    for i, (g, w) in enumerate(zip(got, wantr)):
        if g["id"] != w["id"]:
            print(f"FAIL codec satir {i} id: {g['id']!r} != {w['id']!r}")
            return EXIT_BAD
        if w["v"] is None:
            if g["v"] is not None:
                print(f"FAIL codec satir {i} v NULL beklenirdi: {g['v']!r}")
                return EXIT_BAD
        elif g["v"] is None or decimal.Decimal(g["v"]) != w["v"]:
            print(f"FAIL codec satir {i} v: {g['v']!r} != {w['v']!r}")
            return EXIT_BAD
        if g["s"] != w["s"]:
            print(f"FAIL codec satir {i} s: {g['s']!r} != {w['s']!r}")
            return EXIT_BAD
    print(f"OK codec {want} rg={got_groups} satir={want_rows} kolon=3 p=12 s=3")
    return 0


def gencodec(outdir):
    """pyarrow ile SNAPPY ve ZSTD sikistirilmis Parquet dosyalari uretir."""
    pa, pq = load_pyarrow()
    if not os.path.isdir(outdir):
        os.makedirs(outdir)
    tbl = pa.table({
        "id": pa.array([1, 2, 3], pa.int32()),
        "v": pa.array([decimal.Decimal("12.34"), decimal.Decimal("-0.05"), None],
                      pa.decimal128(10, 2)),
        "s": pa.array(["a", None, "ccc"], pa.string()),
    })
    for name, comp in (("ext_snappy.parquet", "SNAPPY"),
                       ("ext_zstd.parquet", "ZSTD")):
        path = os.path.join(outdir, name)
        pq.write_table(tbl, path, compression=comp)
        pf = pq.ParquetFile(path)
        got = pf.metadata.row_group(0).column(0).compression
        if got.upper() != comp:
            print(f"FAIL gencodec {name}: {got} != {comp}")
            return EXIT_BAD
        print(f"GEN {name} {os.path.getsize(path)} codec={got}")
    return 0


def main(argv):
    if len(argv) < 2:
        print("FAIL kullanim: verify.py selftest|check|gen")
        return EXIT_BAD
    mode = argv[1]
    if mode == "selftest":
        pa, _ = load_pyarrow()
        print(f"OK pyarrow {pa.__version__}")
        return 0
    if mode == "check":
        if len(argv) < 4:
            print("FAIL kullanim: verify.py check <file> arrow|parquet")
            return EXIT_BAD
        return check(argv[2], argv[3])
    if mode == "gen":
        if len(argv) < 3:
            print("FAIL kullanim: verify.py gen <dir>")
            return EXIT_BAD
        return gen(argv[2])
    if mode == "checkcells":
        if len(argv) < 4:
            print("FAIL kullanim: verify.py checkcells <file> arrow|parquet")
            return EXIT_BAD
        return checkcells(argv[2], argv[3])
    if mode == "gennulls":
        if len(argv) < 3:
            print("FAIL kullanim: verify.py gennulls <dir>")
            return EXIT_BAD
        return gennulls(argv[2])
    if mode == "genbig":
        if len(argv) < 3:
            print("FAIL kullanim: verify.py genbig <dir>")
            return EXIT_BAD
        return genbig(argv[2])
    if mode == "genbigparquet":
        if len(argv) < 3:
            print("FAIL kullanim: verify.py genbigparquet <dir>")
            return EXIT_BAD
        return genbigparquet(argv[2])
    if mode == "checkdec":
        if len(argv) < 4:
            print("FAIL kullanim: verify.py checkdec <file> arrow|parquet")
            return EXIT_BAD
        return checkdec(argv[2], argv[3])
    if mode == "gendec":
        if len(argv) < 3:
            print("FAIL kullanim: verify.py gendec <dir>")
            return EXIT_BAD
        return gendec(argv[2])
    if mode == "checkcodec":
        if len(argv) < 6:
            print("FAIL kullanim: verify.py checkcodec <file> <codec> <grup> <satir>")
            return EXIT_BAD
        return checkcodec(argv[2], argv[3], int(argv[4]), int(argv[5]))
    if mode == "gencodec":
        if len(argv) < 3:
            print("FAIL kullanim: verify.py gencodec <dir>")
            return EXIT_BAD
        return gencodec(argv[2])
    print(f"FAIL bilinmeyen mod: {mode}")
    return EXIT_BAD


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL istisna: {exc}")
        sys.exit(EXIT_BAD)
