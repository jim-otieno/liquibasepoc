#!/usr/bin/env bash
# Guided, step-by-step run of the whole expand/contract migration.
# Explains each phase, runs it, then shows the schema so you can see the effect.
#
# Works against whatever the environment points at:
#   eval "$(scripts/local-env.sh)"   # local Docker stack
#   eval "$(scripts/rds-env.sh)"     # AWS RDS
#
#   scripts/walkthrough.sh                 # pauses before each step (learning mode)
#   scripts/walkthrough.sh --no-pause      # runs straight through
#   scripts/walkthrough.sh --with-app      # also rolls the app through v1..v4 (needs the compose app running)
#   scripts/walkthrough.sh --rows 100000   # data size (default 20000)
#
# It creates its own throwaway database (walk_<timestamp>) on the server and
# drops it at the end, so it never touches the 'poc' database or CI's databases.
# Use --keep to leave it in place for exploring with psql/DBeaver.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PAUSE=1 WITH_APP=0 ROWS=20000 KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-pause) PAUSE=0 ;;
    --with-app) WITH_APP=1 ;;
    --rows) ROWS="$2"; shift ;;
    --keep) KEEP=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

: "${DB_HOST:?Set the environment first: eval \"\$(scripts/local-env.sh)\"  or  eval \"\$(scripts/rds-env.sh)\"}"
PY="${PYTHON:-python}"
command -v "$PY" >/dev/null || { echo "python not found - activate the venv: source .venv/Scripts/activate" >&2; exit 1; }

WALK_DB="walk_$(date +%Y%m%d%H%M%S)"
# Point Liquibase at the throwaway database: replace the database name in the
# JDBC URL, keeping any query string such as ?sslmode=require.
LB_URL="$(echo "$LB_URL" | sed -E "s#/[^/?]+(\?|$)#/${WALK_DB}\1#")"
export LB_URL

bold() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }
say()  { printf '   %s\n' "$*"; }
step() {
  bold "$1"; shift
  for line in "$@"; do say "$line"; done
  if [ $PAUSE -eq 1 ]; then read -r -p $'\n   Press Enter to run this step (Ctrl+C to stop)... ' _; fi
}
show() { echo; echo "   --- database now ---"; DB_NAME="$WALK_DB" "$PY" experiments/show_schema.py; }

cleanup() {
  if [ $KEEP -eq 0 ]; then
    DB_NAME="${DB_NAME_ADMIN:-postgres}" "$PY" experiments/ci_database.py drop "$WALK_DB" >/dev/null 2>&1 || true
    echo; echo "   (dropped throwaway database $WALK_DB)"
  else
    echo; echo "   Kept database $WALK_DB on $DB_HOST - drop it later with:"
    echo "   DB_NAME=postgres python experiments/ci_database.py drop $WALK_DB"
  fi
}

bold "Expand/contract walkthrough"
say "server:   $DB_HOST"
say "database: $WALK_DB (throwaway)"
say "Liquibase JDBC URL: $LB_URL"
DB_NAME="${DB_NAME_ADMIN:-postgres}" "$PY" experiments/ci_database.py create "$WALK_DB"
trap cleanup EXIT

step "STEP 0  Lint the changelog" \
  "The phase linter reads every changeset and checks the two invariants:" \
  "  - phase discipline: one label per changeset, destructive changes only in 'contract'" \
  "  - lock safety: CONCURRENTLY/ONLINE, NOT VALID/NOVALIDATE, lock timeouts, rollbacks"
"$PY" tools/phase-linter/phase_lint.py db/changelog/db.changelog-master.yaml

step "STEP 1  Baseline (application v1)" \
  "Creates customer(id, customer_name NOT NULL, email, created_at) and loads $ROWS rows." \
  "This is 'production' before the change. The goal: rename customer_name -> full_name" \
  "without ever locking the table or breaking a running app version."
scripts/deploy-phase.sh baseline walk
DB_NAME="$WALK_DB" "$PY" experiments/seed_data.py --rows "$ROWS"
show

step "STEP 2  EXPAND (label: expand)" \
  "Adds full_name as a NULLABLE column with no default: a metadata-only change, milliseconds." \
  "Also builds an index with CREATE INDEX CONCURRENTLY (writes keep flowing)." \
  "Every DDL starts with SET lock_timeout = '2s': if the lock is busy, Liquibase gives up" \
  "and deploy-phase.sh retries, instead of queueing in front of user traffic." \
  "App v1 still works: nothing it uses has changed."
scripts/deploy-phase.sh expand walk
show
[ $WITH_APP -eq 1 ] && { say "Rolling app to v2 (DUAL_WRITE_READ_OLD): writes both columns, reads old."; scripts/rolling-deploy.sh DUAL_WRITE_READ_OLD; }

step "STEP 3  Rollback demo" \
  "Every phase before contract is reversible. deploy-phase.sh tagged the database" \
  "'pre-expand-walk' before expanding; rolling back to that tag removes full_name and the index." \
  "Then we expand again."
scripts/liquibase.sh rollback --tag=pre-expand-walk
show
scripts/deploy-phase.sh expand walk2

step "STEP 4  MIGRATE gate refuses to run early" \
  "The 'migrate' changeset is only a check: it HALTs while any row has full_name IS NULL." \
  "Running it now (before the backfill) must FAIL - that failure is the safety net."
if scripts/deploy-phase.sh migrate walk >/dev/null 2>&1; then echo "   UNEXPECTED: gate passed"; exit 1; else say "-> refused, as designed."; fi

step "STEP 5  Backfill (outside Liquibase)" \
  "experiments/backfill.py copies customer_name into full_name 5,000 rows at a time" \
  "(keyset pagination, short transactions, throttled). Each batch locks only its own rows." \
  "In production, app v2 is dual-writing meanwhile, so new rows already have both values."
DB_NAME="$WALK_DB" "$PY" experiments/backfill.py --batch 5000 --sleep-ms 0
show

step "STEP 6  MIGRATE (label: migrate)" \
  "Now the gate passes and records the tag rcn-backfill-complete." \
  "verify_integrity.py double-checks every row: full_name present and equal to customer_name."
scripts/deploy-phase.sh migrate walk
DB_NAME="$WALK_DB" "$PY" experiments/verify_integrity.py

step "STEP 7  HARDEN (label: harden)" \
  "Enforce NOT NULL on full_name in two steps, so the full-table check never runs under" \
  "an exclusive lock: ADD CONSTRAINT ... CHECK (full_name IS NOT NULL) NOT VALID (instant)," \
  "then VALIDATE CONSTRAINT (scans the table but lets reads and writes continue)." \
  "Also makes the OLD column nullable, so app v4 (which stops writing it) can insert." \
  "Watch the 'NOT VALID yet' marker appear and disappear in the output."
scripts/deploy-phase.sh harden walk
show
if [ $WITH_APP -eq 1 ]; then
  say "Rolling app to v3 (reads new), then v4 (writes new only)."
  scripts/rolling-deploy.sh DUAL_WRITE_READ_NEW
  scripts/rolling-deploy.sh NEW_ONLY
fi

step "STEP 8  CONTRACT (label: contract) - the one-way door" \
  "Drops customer_name. Its precondition re-checks that no full_name is NULL, and its" \
  "rollback fails on purpose: dropped data cannot be restored by Liquibase." \
  "In the real pipeline this step sits behind a manual approval and a soak period."
scripts/deploy-phase.sh contract walk
DB_NAME="$WALK_DB" "$PY" experiments/verify_integrity.py --after-contract
show

bold "Done. Full history:"
scripts/liquibase.sh history | tail -n 20
