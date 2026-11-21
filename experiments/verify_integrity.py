#!/usr/bin/env python3
"""Integrity gate between phases: every row has a new value equal to the old one.

    python experiments/verify_integrity.py            # before harden / contract
    python experiments/verify_integrity.py --after-contract

Exit code 1 on any mismatch, so the pipeline stops before an irreversible step.
"""
from __future__ import annotations

import argparse
import sys

import db


def scalar(cur, sql: str) -> int:
    cur.execute(sql)
    return int(cur.fetchone()[0])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--after-contract", action="store_true",
                    help="old column is gone; only check the new one")
    args = ap.parse_args()

    with db.connect() as conn:
        cur = conn.cursor()
        total = scalar(cur, "SELECT COUNT(*) FROM customer")
        missing = scalar(cur, "SELECT COUNT(*) FROM customer WHERE full_name IS NULL")
        diff = 0 if args.after_contract else scalar(
            cur, "SELECT COUNT(*) FROM customer WHERE customer_name <> full_name")

    print(f"rows={total:,} full_name_null={missing:,} old_new_mismatch={diff:,}")
    if missing or diff:
        print("INTEGRITY CHECK FAILED", file=sys.stderr)
        return 1
    print("integrity check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
