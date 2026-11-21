"""Generate the external Arrow/Parquet fixtures used by tests/interop_format.

These files are produced by pyarrow (an INDEPENDENT implementation) and then
committed as inert test data, so the always-run Pascal gate can prove that VDB
reads files it did not write. Nothing here runs during the gate; this script is
kept only so the fixtures can be regenerated reproducibly.

    C:\\Python314\\python.exe generate_fixtures.py
"""
import datetime
import os
import sys

sys.path.insert(0, r"C:\Users\Onur2x\AppData\Local\Temp\opencode\pylibs")

import pyarrow as pa
import pyarrow.parquet as pq

HERE = os.path.dirname(os.path.abspath(__file__))
N = 50

ids = list(range(N))
names = [f"row-{i}" for i in range(N)]
scores = [i / 4.0 for i in range(N)]
flags = [(i % 2 == 0) for i in range(N)]
born = [datetime.date(2026, 1, 1) + datetime.timedelta(days=i) for i in range(N)]
seen = [datetime.datetime(2026, 1, 1, 0, 0, 0) + datetime.timedelta(seconds=i * 7)
        for i in range(N)]
blobs = [b"B%d" % i for i in range(N)]

table = pa.table({
    "id": pa.array(ids, pa.int64()),
    "name": pa.array(names, pa.string()),
    "score": pa.array(scores, pa.float64()),
    "flag": pa.array(flags, pa.bool_()),
    "born": pa.array(born, pa.date32()),
    "seen": pa.array(seen, pa.timestamp("ms")),
    "blob": pa.array(blobs, pa.binary()),
})

# Arrow IPC *stream* (what VDB reads/writes), three batches.
with pa.OSFile(os.path.join(HERE, "ext.arrow"), "wb") as sink:
    with pa.ipc.new_stream(sink, table.schema) as writer:
        for i in range(3):
            writer.write_table(table.slice(i * 17, min(17, N - i * 17)))
            if i * 17 + 17 >= N:
                break

# Parquet, uncompressed, three row groups.
pq.write_table(table, os.path.join(HERE, "ext.parquet"),
               compression="NONE", row_group_size=17)

# Parquet, SNAPPY compressed (VDB only reads SNAPPY; it always writes NONE).
pq.write_table(table, os.path.join(HERE, "ext_snappy.parquet"),
               compression="snappy", row_group_size=17)

for f in ("ext.arrow", "ext.parquet", "ext_snappy.parquet"):
    p = os.path.join(HERE, f)
    print(f, os.path.getsize(p))
