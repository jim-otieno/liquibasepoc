#!/usr/bin/env python3
"""Print what the database looks like right now: the customer table's columns,
its constraints and indexes, row counts, and the last Liquibase changesets.

Used by scripts/walkthrough.sh after every phase so you can SEE each phase's effect.

    python experiments/show_schema.py
"""
from __future__ import annotations

import db

COLUMNS = """
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'customer' ORDER BY ordinal_position
"""
CONSTRAINTS = """
SELECT conname, contype, convalidated, pg_get_constraintdef(oid)
FROM pg_constraint WHERE conrelid = 'customer'::regclass ORDER BY conname
"""
INDEXES = "SELECT indexname FROM pg_indexes WHERE tablename = 'customer' ORDER BY indexname"
CHANGELOG = """
SELECT orderexecuted, id, labels, exectype, COALESCE(tag, '')
FROM databasechangelog ORDER BY orderexecuted DESC LIMIT 6
"""


def main() -> None:
    with db.connect() as conn:
        cur = conn.cursor()
        cur.execute("SELECT to_regclass('customer') IS NOT NULL")
        if not cur.fetchone()[0]:
            print("  (no customer table yet)")
            return

        cur.execute(COLUMNS)
        cols = cur.fetchall()
        print("  columns:     " + ", ".join(f"{n} {t}{'' if nul == 'YES' else ' NOT NULL'}" for n, t, nul in cols))

        cur.execute(CONSTRAINTS)
        for name, kind, valid, definition in cur.fetchall():
            state = "" if valid else "  <-- NOT VALID yet (existing rows not checked)"
            print(f"  constraint:  {name}: {definition}{state}")

        cur.execute(INDEXES)
        print("  indexes:     " + ", ".join(r[0] for r in cur.fetchall()))

        names = [c[0] for c in cols]
        if "full_name" in names:
            cur.execute("SELECT COUNT(*), COUNT(*) FILTER (WHERE full_name IS NULL) FROM customer")
            total, missing = cur.fetchone()
            print(f"  rows:        {total:,} total, {missing:,} still missing full_name")
        else:
            cur.execute("SELECT COUNT(*) FROM customer")
            print(f"  rows:        {cur.fetchone()[0]:,}")

        cur.execute(CHANGELOG)
        print("  last changesets (newest first):")
        for order, cid, labels, exectype, tag in cur.fetchall():
            print(f"     #{order:<3} {cid:<36} label={labels or '-':<15} {exectype}{'  tag=' + tag if tag else ''}")


if __name__ == "__main__":
    main()
