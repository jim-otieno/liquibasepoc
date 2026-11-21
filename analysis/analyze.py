#!/usr/bin/env python3
"""Statistical analysis per research question.

Input: results/summary.csv with one row per run, columns
    run_id, arm, change, dbms, load, rows, contention,
    blocked_session_s, failed_requests, p99_ms, ...
Output: Kruskal-Wallis across arms, then pairwise Mann-Whitney U with Holm
correction and Cliff's delta / Vargha-Delaney A12 effect sizes.

    python analysis/analyze.py results/summary.csv --metric blocked_session_s
"""
from __future__ import annotations

import argparse
import itertools

import pandas as pd
from scipy import stats


def cliffs_delta(a, b) -> float:
    gt = sum(1 for x in a for y in b if x > y)
    lt = sum(1 for x in a for y in b if x < y)
    return (gt - lt) / (len(a) * len(b))


def a12(a, b) -> float:
    """Vargha-Delaney A12: probability that a value from a exceeds one from b."""
    return (cliffs_delta(a, b) + 1) / 2


def magnitude(d: float) -> str:
    d = abs(d)  # Romano et al. (2006) thresholds
    return "negligible" if d < 0.147 else "small" if d < 0.33 else "medium" if d < 0.474 else "large"


def holm(pvals: list[float]) -> list[float]:
    order = sorted(range(len(pvals)), key=lambda i: pvals[i])
    adj, running = [0.0] * len(pvals), 0.0
    for rank, i in enumerate(order):
        running = max(running, min(1.0, (len(pvals) - rank) * pvals[i]))
        adj[i] = running
    return adj


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("summary")
    ap.add_argument("--metric", default="blocked_session_s")
    ap.add_argument("--by", nargs="*", default=["change", "dbms"], help="analyse separately per these factors")
    args = ap.parse_args()

    df = pd.read_csv(args.summary)
    for keys, grp in df.groupby(args.by):
        print(f"\n=== {dict(zip(args.by, keys if isinstance(keys, tuple) else (keys,)))} | metric={args.metric}")
        samples = {arm: g[args.metric].dropna().tolist() for arm, g in grp.groupby("arm")}
        samples = {k: v for k, v in samples.items() if len(v) >= 2}
        if len(samples) < 2:
            print("not enough arms with data")
            continue
        for arm, v in samples.items():
            s = pd.Series(v)
            print(f"  {arm:20} n={len(v):3} median={s.median():10.3f} IQR={s.quantile(.75) - s.quantile(.25):10.3f}")
        h, p = stats.kruskal(*samples.values())
        print(f"  Kruskal-Wallis H={h:.3f} p={p:.4g}")
        pairs = list(itertools.combinations(samples, 2))
        raw = [stats.mannwhitneyu(samples[a], samples[b], alternative="two-sided").pvalue for a, b in pairs]
        for (a, b), p_raw, p_adj in zip(pairs, raw, holm(raw)):
            d = cliffs_delta(samples[a], samples[b])
            print(f"  {a} vs {b}: p_holm={p_adj:.4g} delta={d:+.3f} ({magnitude(d)}) A12={a12(samples[a], samples[b]):.3f}")


if __name__ == "__main__":
    main()
