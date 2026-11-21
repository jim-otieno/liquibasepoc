#!/usr/bin/env bash
# Rolling deploy of the application into a new schema mode, one instance at a
# time, behind the nginx load balancer (infra/docker-compose.yml).
#
#   scripts/rolling-deploy.sh DUAL_WRITE_READ_OLD
#
# While app-a restarts, app-b serves (and vice versa), so versions N-1 and N
# run side by side - exactly the overlap the compatibility invariant covers.
set -euo pipefail

MODE="${1:?usage: rolling-deploy.sh <OLD_ONLY|DUAL_WRITE_READ_OLD|DUAL_WRITE_READ_NEW|NEW_ONLY>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "$ROOT/infra/docker-compose.yml")

current_mode() {  # $1 = host port of the instance
  curl -fsS "http://localhost:$1/customers/_mode" 2>/dev/null | sed -E 's/.*"schemaMode":"([A-Z_]+)".*/\1/' || echo OLD_ONLY
}

wait_healthy() {  # $1 = host port
  for _ in $(seq 1 60); do
    if curl -fsS "http://localhost:$1/actuator/health" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "instance on port $1 did not become healthy" >&2
  return 1
}

B_MODE="$(current_mode 8082)"
echo "== app-a -> $MODE (app-b stays on $B_MODE)"
APP_A_MODE="$MODE" APP_B_MODE="$B_MODE" "${COMPOSE[@]}" up -d --no-deps app-a
wait_healthy 8081

echo "== app-b -> $MODE"
APP_A_MODE="$MODE" APP_B_MODE="$MODE" "${COMPOSE[@]}" up -d --no-deps app-b
wait_healthy 8082
echo "== both instances serving $MODE"
