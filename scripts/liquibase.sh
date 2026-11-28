#!/usr/bin/env bash
# Run the Liquibase CLI in Docker against the repo's changelogs.
#
#   scripts/liquibase.sh status --verbose
#   scripts/liquibase.sh update-sql --label-filter=expand
#
# Connection (from env; CI injects these from its secret store):
#   LB_URL, LB_USER, LB_PASSWORD
#   LB_NETWORK      docker network to join (default: host; compose: liquibase-poc_default)
#   LIQUIBASE_IMAGE pinned image (default below)
# Lock-safety overrides (optional; defaults live in db.changelog-master.yaml):
#   LB_LOCK_TIMEOUT      PostgreSQL lock_timeout, e.g. 2s (default) or 0 (no timeout)
#   LB_DDL_LOCK_TIMEOUT  Oracle ddl_lock_timeout in seconds
# They are passed as JVM system properties, which Liquibase uses as changelog
# parameters with priority over the changelog's own defaults.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${LIQUIBASE_IMAGE:-liquibase/liquibase:4.29.2}"
NETWORK="${LB_NETWORK:-host}"
: "${LB_URL:=jdbc:postgresql://localhost:5432/poc}"
: "${LB_USER:=poc}"
: "${LB_PASSWORD:=poc}"

# On Windows (Git Bash), give Docker a C:/... path it can mount;
# MSYS_NO_PATHCONV stops Git Bash rewriting the /liquibase/... container paths.
HOST_ROOT="$ROOT"
if command -v cygpath >/dev/null 2>&1; then HOST_ROOT="$(cygpath -m "$ROOT")"; fi

JAVA_PROPS=""
[ -n "${LB_LOCK_TIMEOUT:-}" ] && JAVA_PROPS+=" -Dlock_timeout=${LB_LOCK_TIMEOUT}"
[ -n "${LB_DDL_LOCK_TIMEOUT:-}" ] && JAVA_PROPS+=" -Dddl_lock_timeout=${LB_DDL_LOCK_TIMEOUT}"

MSYS_NO_PATHCONV=1 docker run --rm --network "$NETWORK" \
  -e JAVA_OPTS="${JAVA_PROPS# }" \
  -v "$HOST_ROOT/db/changelog:/liquibase/changelog:ro" \
  "$IMAGE" \
  --search-path=/liquibase/changelog \
  --changelog-file=db.changelog-master.yaml \
  --url="$LB_URL" --username="$LB_USER" --password="$LB_PASSWORD" \
  "$@"
