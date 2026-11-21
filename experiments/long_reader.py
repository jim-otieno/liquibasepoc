#!/usr/bin/env python3
"""Inject a long-running reader during DDL (factor: contention).

Holds an open transaction that has read the customer table, so any DDL that
needs an exclusive lock must wait behind it. This is the lock-queue scenario
where naive migrations block all traffic and lock timeouts make the difference.

    python experiments/long_reader.py --hold-s 30
"""
from __future__ import annotations

import argparse
import time

import db


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hold-s", type=float, default=30)
    args = ap.parse_args()
    with db.connect() as conn:
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM customer")  # takes ACCESS SHARE (PG) for the whole transaction
        cur.fetchone()
        print(f"long_reader: holding transaction for {args.hold_s}s")
        time.sleep(args.hold_s)
        conn.rollback()
    print("long_reader: released")


if __name__ == "__main__":
    main()
