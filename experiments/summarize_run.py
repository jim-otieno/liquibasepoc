#!/usr/bin/env python3
"""Turn one run's raw measurements into results per phase (RQ1 measures).

Inputs (all in the run's results directory):
    phases.csv   phase,event,ts_utc            written by scripts/mark.sh
    locks.csv    one row per blocked session    written by experiments/lock_sampler.py
    k6.csv       one row per k6 metric sample   k6 --out csv=k6.csv

Output: a table on stdout and summary.csv (one row per phase, plus 'total').

    python experiments/summarize_run.py results/3 --run-id jenkins-3 --interval-ms 100

Only the Python standard library is used, so it runs on the Jenkins host as is.
"""
from __future__ import annotations

import argparse
import csv
from datetime import datetime
from pathlib import Path


def ts(value: str) -> float:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def load_phases(path: Path) -> list[tuple[str, float, float]]:
    starts: dict[str, float] = {}
    out = []
    with path.open() as fh:
        for row in csv.DictReader(fh):
            if row["event"] == "start":
                starts[row["phase"]] = ts(row["ts_utc"])
            elif row["event"] == "end" and row["phase"] in starts:
                out.append((row["phase"], starts.pop(row["phase"]), ts(row["ts_utc"])))
    return out


def load_locks(path: Path) -> list[tuple[float, float]]:
    """(sample time, wait seconds) per blocked session per sample."""
    if not path.exists():
        return []
    out = []
    with path.open() as fh:
        for row in csv.DictReader(fh):
            try:
                out.append((ts(row["ts_utc"]), float(row["wait_s"] or 0)))
            except (KeyError, ValueError):
                continue
    return out


def load_k6(path: Path) -> tuple[list[tuple[float, float]], list[tuple[float, float]]]:
    """(time, 1/0) per probe request, and (time, ms) per HTTP request duration."""
    avail, dur = [], []
    if not path.exists():
        return avail, dur
    with path.open() as fh:
        for row in csv.DictReader(fh):
            name = row.get("metric_name")
            if name not in ("zdm_available", "http_req_duration"):
                continue
            try:
                t, v = float(row["timestamp"]), float(row["metric_value"])
            except (KeyError, ValueError):
                continue
            (avail if name == "zdm_available" else dur).append((t, v))
    return avail, dur


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("results", type=Path)
    ap.add_argument("--run-id", default="")
    ap.add_argument("--interval-ms", type=int, default=100)
    args = ap.parse_args()

    phases = load_phases(args.results / "phases.csv")
    locks = load_locks(args.results / "locks.csv")
    avail, dur = load_k6(args.results / "k6.csv")
    step = args.interval_ms / 1000

    rows = []
    spans = phases + ([("total", phases[0][1], phases[-1][2])] if phases else [])
    for name, t0, t1 in spans:
        lk = [w for t, w in locks if t0 <= t <= t1]
        # k6 timestamps are whole seconds: give each second to the one phase that
        # contains its midpoint, so no request is counted in two phases.
        av = [v for t, v in avail if t0 <= t + 0.5 < t1]
        du = [v for t, v in dur if t0 <= t + 0.5 < t1]
        failed = sum(1 for v in av if v < 1)
        rows.append({
            "run_id": args.run_id,
            "phase": name,
            "seconds": round(t1 - t0, 1),
            "blocked_session_s": round(len(lk) * step, 2),
            "max_lock_wait_s": round(max(lk), 2) if lk else 0,
            "requests": len(av),
            "failed_requests": failed,
            "availability_pct": round(100 * (len(av) - failed) / len(av), 3) if av else "",
            "p95_ms": round(percentile(du, 95), 1) if du else "",
            "p99_ms": round(percentile(du, 99), 1) if du else "",
        })

    out = args.results / "summary.csv"
    if rows:
        with out.open("w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0]))
            w.writeheader()
            w.writerows(rows)

    hdr = f"{'phase':<16}{'sec':>7}{'blocked s':>11}{'max wait':>10}{'requests':>10}{'failed':>8}{'avail %':>9}{'p95 ms':>9}{'p99 ms':>9}"
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        print(f"{r['phase']:<16}{r['seconds']:>7}{r['blocked_session_s']:>11}{r['max_lock_wait_s']:>10}"
              f"{r['requests']:>10}{r['failed_requests']:>8}{str(r['availability_pct']):>9}"
              f"{str(r['p95_ms']):>9}{str(r['p99_ms']):>9}")
    print(f"\nwrote {out}")


if __name__ == "__main__":
    main()
