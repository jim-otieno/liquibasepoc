#!/usr/bin/env python3
"""Create or drop a throwaway database on the shared RDS instance.

Each CI run gets its own database, so runs on one instance never see each
other's tables, locks or DATABASECHANGELOG rows.

    DB_NAME=postgres python experiments/ci_database.py create ci_12345_1
    DB_NAME=postgres python experiments/ci_database.py drop   ci_12345_1

Connects with the DB_* variables (see db.py) to the maintenance database.
"""
from __future__ import annotations

import re
import sys

import db


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in {"create", "drop"}:
        print(__doc__)
        return 2
    action, name = sys.argv[1], sys.argv[2]
    if not re.fullmatch(r"[a-z][a-z0-9_]{0,62}", name):
        print(f"refusing unsafe database name: {name!r}", file=sys.stderr)
        return 2
    with db.connect(autocommit=True) as conn:
        cur = conn.cursor()
        if action == "create":
            cur.execute(f"CREATE DATABASE {name}")
        else:
            # PostgreSQL 13+: terminate leftover sessions (e.g. a killed sampler) and drop.
            cur.execute(f"DROP DATABASE IF EXISTS {name} WITH (FORCE)")
    print(f"{'created' if action == 'create' else 'dropped'} database {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
