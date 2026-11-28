#!/usr/bin/env bash
# Record a phase boundary for later analysis (UTC, millisecond precision).
#
#   scripts/mark.sh results/3 expand start
#   scripts/mark.sh results/3 expand end
#
# Appends "phase,event,ts_utc" to <dir>/phases.csv; experiments/summarize_run.py
# uses it to attribute blocked sessions and failed requests to each phase.
set -euo pipefail
DIR="${1:?results dir}" PHASE="${2:?phase}" EVENT="${3:?start|end}"
mkdir -p "$DIR"
[ -f "$DIR/phases.csv" ] || echo "phase,event,ts_utc" > "$DIR/phases.csv"
echo "$PHASE,$EVENT,$(date -u +%Y-%m-%dT%H:%M:%S.%3N+00:00)" >> "$DIR/phases.csv"
