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
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${LIQUIBASE_IMAGE:-liquibase/liquibase:4.29.2}"
NETWORK="${LB_NETWORK:-host}"
: "${LB_URL:=jdbc:postgresql://localhost:5432/poc}"
: "${LB_USER:=poc}"
: "${LB_PASSWORD:=poc}"

# MSYS_NO_PATHCONV stops Git Bash on Windows rewriting /liquibase/... paths.
MSYS_NO_PATHCONV=1 docker run --rm --network "$NETWORK" \
  -v "$ROOT/db/changelog:/liquibase/changelog:ro" \
  "$IMAGE" \
  --search-path=/liquibase/changelog \
  --changelog-file=db.changelog-master.yaml \
  --url="$LB_URL" --username="$LB_USER" --password="$LB_PASSWORD" \
  "$@"
