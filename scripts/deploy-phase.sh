#!/usr/bin/env bash
# Deploy one phase of the expand/contract model.
#
#   scripts/deploy-phase.sh expand [build-id]
#
# 1. tags the database (rollback target: liquibase rollback --tag=<tag>)
# 2. runs `update --label-filter=<phase>`
# 3. on a lock timeout, backs off and retries (lock-safety invariant):
#    the DDL gave up instead of queueing in front of user traffic.
set -euo pipefail

PHASE="${1:?usage: deploy-phase.sh <baseline|expand|migrate|migrate-inline|harden|contract> [build-id]}"
BUILD="${2:-local-$(date +%Y%m%d%H%M%S)}"
MAX_ATTEMPTS="${LB_MAX_ATTEMPTS:-5}"
LB="$(dirname "${BASH_SOURCE[0]}")/liquibase.sh"

case "$PHASE" in
  baseline|expand|migrate|migrate-inline|harden|contract) ;;
  *) echo "unknown phase: $PHASE" >&2; exit 2 ;;
esac

TAG="pre-${PHASE}-${BUILD}"
echo "== tagging database: $TAG"
"$LB" tag --tag="$TAG"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  echo "== update --label-filter=$PHASE (attempt $attempt/$MAX_ATTEMPTS)"
  set +e
  out="$("$LB" update --label-filter="$PHASE" 2>&1)"
  rc=$?
  set -e
  echo "$out"
  if [ $rc -eq 0 ]; then
    echo "== phase $PHASE deployed (rollback tag: $TAG)"
    exit 0
  fi
  # PostgreSQL: 'canceling statement due to lock timeout' (55P03)
  # Oracle: ORA-00054 resource busy / ORA-04021 timeout waiting to lock object
  if echo "$out" | grep -qiE 'lock timeout|55P03|ORA-00054|ORA-04021'; then
    sleep_s=$(( attempt * attempt * 2 ))
    echo "== lock timeout: DDL yielded to traffic; retrying in ${sleep_s}s"
    sleep "$sleep_s"
    continue
  fi
  echo "== phase $PHASE failed (not a lock timeout)" >&2
  exit $rc
done
echo "== phase $PHASE: gave up after $MAX_ATTEMPTS lock timeouts" >&2
exit 1
