#!/usr/bin/env bash
# One experiment run: reset, seed, start probes, run the arm's migration, stop probes.
# Called by experiments/run_matrix.py via experiments/arms.json.
#
#   scripts/run-arm.sh <arm> <run_id> <change> <dbms> <load> <rows> <contention> <results_dir>
#
# STATUS: the A3 (dual-write) and A4 (enforced) arms are implemented for
# change C3 on PostgreSQL. The other arms and changes are stubs to fill in
# during work-plan months 3-4.
set -euo pipefail

ARM="$1" RUN="$2" CHANGE="$3" DBMS="$4" LOAD="$5" ROWS="$6" CONTENTION="$7" RESULTS="$8"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$RESULTS/$RUN"
mkdir -p "$OUT"
cd "$ROOT"

case "$LOAD" in low) RATE=10 ;; medium) RATE=50 ;; high) RATE=200 ;; *) RATE=10 ;; esac
export DB_KIND="$DBMS"

if [ "$DBMS" != "postgresql" ] || [ "$CHANGE" != "C3-rename-column" ]; then
  echo "run-arm: $ARM/$CHANGE/$DBMS not implemented yet" >&2; exit 3
fi

echo "== [$RUN] reset database and seed $ROWS rows"
docker compose -f infra/docker-compose.yml exec -T postgres \
  psql -U poc -d poc -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
scripts/deploy-phase.sh baseline "$RUN"
python experiments/seed_data.py --rows "$ROWS"
scripts/rolling-deploy.sh OLD_ONLY

echo "== [$RUN] start probes"
python experiments/lock_sampler.py --run-id "$RUN" --out "$OUT/locks.csv" & SAMPLER=$!
k6 run -q -e RATE="$RATE" -e DURATION=30m -e MAX_ID="$ROWS" \
  --summary-export "$OUT/k6-summary.json" --out "json=$OUT/k6.json" load/k6-availability.js & K6=$!
sleep 10   # warm-up / baseline window
if [ "$CONTENTION" = "long-reader" ]; then
  python experiments/long_reader.py --hold-s 20 & sleep 1
fi

echo "== [$RUN] arm $ARM"
case "$ARM" in
  dual-write|enforced)
    if [ "$ARM" = "enforced" ]; then
      python tools/phase-linter/phase_lint.py db/changelog/db.changelog-master.yaml
    fi
    scripts/deploy-phase.sh expand "$RUN"
    scripts/rolling-deploy.sh DUAL_WRITE_READ_OLD
    python experiments/backfill.py --out "$OUT/backfill.csv"
    scripts/deploy-phase.sh migrate "$RUN"
    python experiments/verify_integrity.py
    scripts/deploy-phase.sh harden "$RUN"
    scripts/rolling-deploy.sh DUAL_WRITE_READ_NEW
    scripts/rolling-deploy.sh NEW_ONLY
    scripts/deploy-phase.sh contract "$RUN"
    python experiments/verify_integrity.py --after-contract
    ;;
  naive)
    # Baseline arm: one release, in-place rename, app restarted into NEW_ONLY.
    echo "TODO: naive in-place RENAME COLUMN arm" >&2; exit 3 ;;
  trigger)
    echo "TODO: trigger-based synchronisation arm" >&2; exit 3 ;;
  cdc)
    echo "TODO: Debezium / GoldenGate Free blue-green arm" >&2; exit 3 ;;
esac

sleep 10   # cool-down window
kill "$K6" "$SAMPLER" 2>/dev/null || true
wait || true
echo "== [$RUN] done -> $OUT"
