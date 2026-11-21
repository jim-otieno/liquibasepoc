#!/usr/bin/env python3
"""Load N synthetic customers into the baseline schema (factor: data size).

    python experiments/seed_data.py --rows 1000000
"""
from __future__ import annotations

import argparse
import random
import string
import time

import db


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=1_000_000)
    ap.add_argument("--batch", type=int, default=10_000)
    ap.add_argument("--seed", type=int, default=42, help="fixed seed for reproducible data")
    args = ap.parse_args()

    rnd = random.Random(args.seed)
    sql = f"INSERT INTO customer (customer_name, email) VALUES ({db.param(1)}, {db.param(2)})"
    t0 = time.time()
    with db.connect() as conn:
        cur = conn.cursor()
        done = 0
        while done < args.rows:
            n = min(args.batch, args.rows - done)
            rows = []
            for _ in range(n):
                first = "".join(rnd.choices(string.ascii_lowercase, k=7)).title()
                last = "".join(rnd.choices(string.ascii_lowercase, k=9)).title()
                rows.append((f"{first} {last}", f"{first}.{last}{done}@example.org".lower()))
            cur.executemany(sql, rows)
            conn.commit()
            done += n
            print(f"\r{done:,}/{args.rows:,} rows", end="", flush=True)
    print(f"\nseeded {args.rows:,} rows in {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
