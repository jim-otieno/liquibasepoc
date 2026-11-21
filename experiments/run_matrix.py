#!/usr/bin/env python3
"""Factorial experiment runner: builds a randomised run plan and executes it.

Each run = one (arm, change, dbms, load, rows, contention, replicate) cell.
The command for a run is a template in experiments/arms.json, so the runner
stays independent of how each arm deploys. Dry-run by default.

    python experiments/run_matrix.py --plan-only                # write results/plan.csv
    python experiments/run_matrix.py --execute --replicates 30  # run everything
"""
from __future__ import annotations

import argparse
import csv
import itertools
import json
import random
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent

FACTORS = {
    "arm": ["A1-naive", "A2-trigger", "A3-app-dual-write", "A4-enforced", "A5-cdc"],
    "change": ["C3-rename-column", "C6-add-index"],
    "dbms": ["postgresql", "oracle"],
    "load": ["low", "medium", "high"],
    "rows": [1_000_000, 10_000_000],
    "contention": ["none", "long-reader"],
}


def build_plan(replicates: int, seed: int, only: dict[str, list[str]]) -> list[dict]:
    levels = {k: [v for v in vs if not only.get(k) or str(v) in only[k]] for k, vs in FACTORS.items()}
    cells = [dict(zip(levels, combo)) for combo in itertools.product(*levels.values())]
    plan = [dict(cell, replicate=r) for cell in cells for r in range(1, replicates + 1)]
    random.Random(seed).shuffle(plan)  # randomised run order (internal validity)
    for i, run in enumerate(plan, 1):
        run["run_id"] = f"r{i:05d}"
    return plan


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--replicates", type=int, default=30)
    ap.add_argument("--seed", type=int, default=20261121)
    ap.add_argument("--only", action="append", default=[], metavar="FACTOR=v1,v2",
                    help="restrict a factor, e.g. --only dbms=postgresql --only arm=A1-naive,A3-app-dual-write")
    ap.add_argument("--plan-only", action="store_true")
    ap.add_argument("--execute", action="store_true")
    ap.add_argument("--results", type=Path, default=HERE.parent / "results")
    args = ap.parse_args()

    only = {}
    for spec in args.only:
        k, v = spec.split("=", 1)
        only[k] = v.split(",")

    plan = build_plan(args.replicates, args.seed, only)
    args.results.mkdir(parents=True, exist_ok=True)
    plan_file = args.results / "plan.csv"
    with plan_file.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(plan[0].keys()))
        w.writeheader()
        w.writerows(plan)
    print(f"plan: {len(plan)} runs -> {plan_file}")
    if args.plan_only or not args.execute:
        if not args.execute:
            print("dry run: pass --execute to run the plan")
        return

    arms = json.loads((HERE / "arms.json").read_text())
    log_file = args.results / "runs.csv"
    new_log = not log_file.exists()
    with log_file.open("a", newline="") as fh:
        w = csv.writer(fh)
        if new_log:
            w.writerow(["run_id", "started_utc", "seconds", "exit_code"])
        for run in plan:
            cmd = arms[run["arm"]].format(**run, results=str(args.results))
            started = datetime.now(timezone.utc).isoformat(timespec="seconds")
            t0 = time.time()
            print(f"[{run['run_id']}] {cmd}")
            rc = subprocess.call(cmd, shell=True)
            w.writerow([run["run_id"], started, f"{time.time() - t0:.1f}", rc])
            fh.flush()


if __name__ == "__main__":
    main()
