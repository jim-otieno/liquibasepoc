#!/usr/bin/env python3
"""Sample blocked sessions every N ms while a migration phase runs (RQ1 primary measure).

Writes one CSV row per blocked session per sample. Blocked-session-seconds
= number of rows x interval. Stop with Ctrl+C or --duration.

    python experiments/lock_sampler.py --interval-ms 100 --out results/locks.csv
"""
from __future__ import annotations

import argparse
import csv
import signal
import time
from datetime import datetime, timezone
from pathlib import Path

import db

PG_SQL = """
SELECT a.pid,
       pg_blocking_pids(a.pid)                       AS blocked_by,
       a.wait_event_type,
       a.wait_event,
       EXTRACT(EPOCH FROM (now() - a.query_start))   AS wait_s,
       l.mode,
       left(a.query, 200)                            AS query
FROM pg_stat_activity a
LEFT JOIN pg_locks l ON l.pid = a.pid AND NOT l.granted
WHERE cardinality(pg_blocking_pids(a.pid)) > 0
  AND a.datname = current_database()   -- shared instance: count only this run's database
"""

# Needs SELECT on v$session (grant SELECT_CATALOG_ROLE to the sampling user).
ORA_SQL = """
SELECT s.sid,
       s.blocking_session,
       s.wait_class,
       s.event,
       s.seconds_in_wait,
       NULL AS lock_mode,
       SUBSTR(q.sql_text, 1, 200)
FROM v$session s
LEFT JOIN v$sql q ON q.sql_id = s.sql_id AND q.child_number = 0
WHERE s.blocking_session IS NOT NULL
"""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval-ms", type=int, default=100)
    ap.add_argument("--duration", type=float, default=0, help="seconds; 0 = until interrupted")
    ap.add_argument("--run-id", default="")
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    stop = False

    def _stop(*_):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    query = ORA_SQL if db.kind() == "oracle" else PG_SQL
    samples = blocked_rows = 0
    t_end = time.time() + args.duration if args.duration else None
    with db.connect(autocommit=True) as conn, args.out.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["run_id", "ts_utc", "session", "blocked_by", "wait_class", "event", "wait_s", "lock_mode", "query"])
        cur = conn.cursor()
        while not stop and (t_end is None or time.time() < t_end):
            t0 = time.perf_counter()
            ts = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
            cur.execute(query)
            for row in cur.fetchall():
                w.writerow([args.run_id, ts, *row])
                blocked_rows += 1
            samples += 1
            time.sleep(max(0.0, args.interval_ms / 1000 - (time.perf_counter() - t0)))

    print(f"lock_sampler: {samples} samples, blocked-session-seconds = "
          f"{blocked_rows * args.interval_ms / 1000:.2f}")


if __name__ == "__main__":
    main()
