#!/usr/bin/env python3
"""M8: VDB <-> SQLite WHERE diferansiyel testi.

Ayni sema + ayni satirlar + ayni WHERE yuklemleri iki motorda calistirilir;
`SELECT id ... ORDER BY id` sonuc kumeleri karsilastirilir.

VDB tarafi `vdbbatch.exe` ile toplu calisir. SQLite tarafi Python'un
yerlesik `sqlite3` moduludur. NULL/uc-degerli mantik, IN/NOT IN,
BETWEEN/NOT BETWEEN ve LIKE icin bagimsiz bir oracle saglar.

Kullanim:
    python sqlite_diff.py [sorgu_sayisi] [seed]
    python sqlite_diff.py 1000 42 --vdbbatch vdbbatch.exe

Cikis kodu 0 = fark yok, 1 = fark/istisna var.
"""
from __future__ import annotations

import argparse
import random
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

TEXT_VALUES = [
    "k0", "k1", "k2", "k10", "abc", "x%y", "a'b", "_z", "ZZ", "k_",
]
LIKE_PATTERNS = [
    "k%", "k_", "%0", "a%", "%b%", "x%y", "%", "_z", "k0", "K%",
]
OPS = ["=", "<>", "<", ">", "<=", ">="]


def sql_lit(v) -> str:
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return f"{v:.2f}"
    return "'" + str(v).replace("'", "''") + "'"


def rand_int(rng: random.Random) -> int:
    return rng.randint(-20, 120)


def rand_float(rng: random.Random) -> float:
    return rng.randint(-20, 120) / 4.0


def rand_text(rng: random.Random) -> str:
    return rng.choice(TEXT_VALUES)


def leaf(rng: random.Random) -> str:
    col = rng.choice("afsb")

    if rng.random() < 0.10:
        neg = "NOT " if rng.random() < 0.5 else ""
        return f"{col} IS {neg}NULL"

    if col in ("a", "f"):
        if rng.random() < 0.18:
            v1 = rand_int(rng) if col == "a" else rand_float(rng)
            v2 = rand_int(rng) if col == "a" else rand_float(rng)
            if v1 > v2:
                v1, v2 = v2, v1
            neg = "NOT " if rng.random() < 0.5 else ""
            return f"{col} {neg}BETWEEN {sql_lit(v1)} AND {sql_lit(v2)}"

        if rng.random() < 0.18:
            vals = [
                rand_int(rng) if col == "a" else rand_float(rng)
                for _ in range(rng.randint(1, 4))
            ]
            if rng.random() < 0.15:
                vals.append(None)
            neg = "NOT " if rng.random() < 0.5 else ""
            return f"{col} {neg}IN ({', '.join(sql_lit(v) for v in vals)})"

        op = rng.choice(OPS)
        v = None if rng.random() < 0.18 else (
            rand_int(rng) if col == "a" else rand_float(rng)
        )
        return f"{col} {op} {sql_lit(v)}"

    if col == "s":
        if rng.random() < 0.30:
            pat = rng.choice(LIKE_PATTERNS)
            neg = "NOT " if rng.random() < 0.5 else ""
            return f"s {neg}LIKE {sql_lit(pat)}"
        if rng.random() < 0.18:
            vals = [rand_text(rng) for _ in range(rng.randint(1, 4))]
            if rng.random() < 0.15:
                vals.append(None)
            neg = "NOT " if rng.random() < 0.5 else ""
            return f"s {neg}IN ({', '.join(sql_lit(v) for v in vals)})"
        op = rng.choice(["=", "<>"])
        v = None if rng.random() < 0.15 else rand_text(rng)
        return f"s {op} {sql_lit(v)}"

    # BOOLEAN
    op = rng.choice(["=", "<>"])
    v = None if rng.random() < 0.15 else rng.choice([True, False])
    return f"b {op} {sql_lit(v)}"


def gen_expr(rng: random.Random, depth: int) -> str:
    if depth <= 0 or rng.random() < 0.42:
        e = leaf(rng)
        if rng.random() < 0.15:
            e = f"NOT ({e})"
        return e
    left = gen_expr(rng, depth - 1)
    right = gen_expr(rng, depth - 1)
    op = "AND" if rng.random() < 0.5 else "OR"
    e = f"({left} {op} {right})"
    if rng.random() < 0.10:
        e = f"NOT {e}"
    return e


def make_rows(rng: random.Random, count: int):
    rows = []
    for i in range(1, count + 1):
        a = None if rng.random() < 0.08 else rand_int(rng)
        f = None if rng.random() < 0.08 else rand_float(rng)
        s = None if rng.random() < 0.10 else rand_text(rng)
        b = None if rng.random() < 0.10 else rng.choice([True, False])
        rows.append((i, a, f, s, b))
    return rows


def parse_vdb_output(text: str):
    lines = text.splitlines()
    blocks = []
    i = 0
    while i < len(lines):
        if lines[i] == "R":
            i += 1
            rows = []
            while i < len(lines) and lines[i] != ".":
                rows.append(lines[i])
                i += 1
            blocks.append(("R", rows))
            i += 1
        elif lines[i] == "E":
            i += 1
            msg = []
            while i < len(lines) and lines[i] != ".":
                msg.append(lines[i])
                i += 1
            blocks.append(("E", "\n".join(msg)))
            i += 1
        else:
            i += 1
    return blocks


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("queries", nargs="?", type=int, default=1000)
    ap.add_argument("seed", nargs="?", type=int, default=20261019)
    ap.add_argument("--rows", type=int, default=400)
    ap.add_argument("--vdbbatch", default="vdbbatch.exe")
    args = ap.parse_args()

    count = max(1, args.queries)
    rng = random.Random(args.seed)
    rows = make_rows(rng, max(1, args.rows))
    queries = [
        "SELECT id FROM t WHERE " + gen_expr(rng, 3) + " ORDER BY id"
        for _ in range(count)
    ]

    schema = (
        "CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, f FLOAT, "
        "s TEXT, b BOOLEAN)"
    )
    inserts = [
        "INSERT INTO t VALUES ({}, {}, {}, {}, {})".format(
            sql_lit(r[0]), sql_lit(r[1]), sql_lit(r[2]), sql_lit(r[3]), sql_lit(r[4])
        )
        for r in rows
    ]

    con = sqlite3.connect(":memory:")
    con.execute("PRAGMA case_sensitive_like=ON")
    con.execute(schema)
    con.executemany("INSERT INTO t VALUES (?, ?, ?, ?, ?)", rows)
    sqlite_results = []
    for q in queries:
        try:
            sqlite_results.append([str(r[0]) for r in con.execute(q).fetchall()])
        except Exception as exc:  # noqa: BLE001
            sqlite_results.append(("ERR", str(exc)))

    exe = Path(args.vdbbatch)
    if not exe.is_absolute():
        exe = Path(__file__).resolve().parent / exe
    if not exe.exists():
        print(f"vdbbatch bulunamadi: {exe}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="vdbsqlite_") as td:
        dbdir = Path(td) / "db"
        dbdir.mkdir()
        sqlfile = Path(td) / "batch.sql"
        sqlfile.write_text(
            "\n".join([schema] + inserts + queries) + "\n", encoding="utf-8"
        )
        proc = subprocess.run(
            [str(exe), str(dbdir), str(sqlfile)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )

    if proc.returncode != 0:
        print(f"vdbbatch cikis kodu {proc.returncode}", file=sys.stderr)
        print(proc.stderr, file=sys.stderr)
        return 2

    blocks = parse_vdb_output(proc.stdout)
    expected_blocks = 1 + len(inserts) + len(queries)
    if len(blocks) != expected_blocks:
        print(
            f"vdbbatch blok sayisi uyusmuyor: {len(blocks)} != {expected_blocks}",
            file=sys.stderr,
        )
        print(proc.stdout[-2000:], file=sys.stderr)
        return 2

    setup_blocks = blocks[: 1 + len(inserts)]
    query_blocks = blocks[1 + len(inserts):]
    for idx, (kind, payload) in enumerate(setup_blocks):
        if kind == "E":
            print(f"VDB kurulum hatasi (blok {idx}): {payload}", file=sys.stderr)
            return 2

    mismatches = 0
    for qi, (q, exp, block) in enumerate(
        zip(queries, sqlite_results, query_blocks), start=1
    ):
        kind, payload = block
        if kind == "E":
            mismatches += 1
            print(f"HATA #{qi} seed={args.seed}")
            print(f"  WHERE: {q}")
            print(f"  VDB: {payload}")
            if mismatches >= 20:
                print("20 hatadan sonra durduruldu.")
                break
            continue

        got = [row.split("\t")[0] for row in payload]
        if isinstance(exp, tuple):
            mismatches += 1
            print(f"SQLITE HATASI #{qi}: {exp[1]}")
            continue
        if got != exp:
            mismatches += 1
            print(f"FARK #{qi} seed={args.seed}")
            print(f"  WHERE: {q}")
            print(f"  SQLite: {','.join(exp)}")
            print(f"  VDB   : {','.join(got)}")
            if mismatches >= 20:
                print("20 farktan sonra durduruldu.")
                break

    if mismatches == 0:
        print(f"SONUC: {count} sorgu, 0 fark (seed={args.seed}, satir={len(rows)})")
        return 0
    print(f"SONUC: {mismatches} fark/hata (seed={args.seed})")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
