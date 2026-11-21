#!/usr/bin/env python3
"""Batched, throttled, idempotent, resumable backfill (MIGRATE phase, default arm).

Copies customer.customer_name into customer.full_name using keyset
pagination, so each transaction locks only one batch of rows for
milliseconds. Safe to stop and re-run at any time.

    python experiments/backfill.py --batch 5000 --sleep-ms 50 --out results/backfill.csv
"""
from __future__ import annotations

import argparse
import csv
import time
from pathlib import Path

import db


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--batch", type=int, default=5000)
    ap.add_argument("--sleep-ms", type=int, default=50, help="throttle between batches")
    ap.add_argument("--out", type=Path, help="CSV of per-batch timings (optional)")
    args = ap.parse_args()

    p1, p2 = db.param(1), db.param(2)
    select_max = (f"SELECT MAX(id) FROM (SELECT id FROM customer WHERE id > {p1} ORDER BY id "
                  + ("FETCH FIRST " + p2 + " ROWS ONLY" if db.kind() == "oracle" else f"LIMIT {p2}")
                  + ") t")
    update = (f"UPDATE customer SET full_name = customer_name "
              f"WHERE id > {p1} AND id <= {p2} AND full_name IS NULL")

    writer = None
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        fh = args.out.open("w", newline="")
        writer = csv.writer(fh)
        writer.writerow(["batch", "from_id", "to_id", "rows_updated", "ms"])

    last_id, total, batch_no = 0, 0, 0
    t_start = time.time()
    with db.connect() as conn:
        cur = conn.cursor()
        while True:
            cur.execute(select_max, (last_id, args.batch))
            upper = cur.fetchone()[0]
            if upper is None:
                break
            t0 = time.perf_counter()
            cur.execute(update, (last_id, upper))
            n = cur.rowcount
            conn.commit()
            ms = (time.perf_counter() - t0) * 1000
            batch_no += 1
            total += n
            if writer:
                writer.writerow([batch_no, last_id, upper, n, f"{ms:.1f}"])
            last_id = upper
            if args.sleep_ms:
                time.sleep(args.sleep_ms / 1000)

    print(f"backfill: {total:,} rows in {batch_no} batches, {time.time() - t_start:.1f}s")


if __name__ == "__main__":
    main()
