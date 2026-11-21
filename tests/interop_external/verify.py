"""Independent (pyarrow) side of tests/interop_external.

Modes
  selftest            -> import pyarrow, print version
  check <file> arrow  -> VDB'in yazdigi Arrow IPC stream'i dogrular
  check <file> parquet-> VDB'in yazdigi Parquet'i dogrular
  gen <dir>           -> pyarrow ile harici Arrow/Parquet dosyalari uretir

Exit 0 = tum dogrulamalar gecti. Exit 2 = dogrulama basarisiz (ayrinti stdout).
Bu betik yalniz TEST tarafidir; depoya yeni bir calisma-zamani bagimliligi
eklemez ve VDB'nin uretim kodu bu betige bagli degildir.
"""
import datetime
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
    print(f"FAIL bilinmeyen mod: {mode}")
    return EXIT_BAD


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL istisna: {exc}")
        sys.exit(EXIT_BAD)
