#!/usr/bin/env bash
# Run the two app instances + nginx with plain `docker run` (no Docker Compose),
# e.g. on the Jenkins EC2 host, against the database in $APP_DB_URL.
#
#   scripts/docker-apps.sh build             # build the app image (zdm-app)
#   scripts/docker-apps.sh up   OLD_ONLY     # start app-a, app-b, then nginx on :$LB_PORT
#   scripts/docker-apps.sh roll DUAL_WRITE_READ_OLD   # rolling restart into a new mode
#   scripts/docker-apps.sh down              # remove everything
#
# Needs APP_DB_URL, APP_DB_USER, APP_DB_PASSWORD (scripts/rds-env.sh exports them).
# The apps get fixed IPs on their own network, so nginx keeps reaching them
# across rolling restarts. The RDS hostname is pinned to the address the host
# resolves (its private VPC address), because containers may otherwise resolve
# the public one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${APP_IMAGE:-zdm-app:latest}"
NET="zdm-net"
SUBNET="172.28.0.0/24"
LB_PORT="${LB_PORT:-8090}"           # Jenkins itself listens on 8080
NGINX_IMAGE="nginx:1.27-alpine"

declare -A IP=([app-a]=172.28.0.11 [app-b]=172.28.0.12)
declare -A PORT=([app-a]=8081 [app-b]=8082)

need_db() { : "${APP_DB_URL:?APP_DB_URL not set: eval \"\$(scripts/rds-env.sh <db>)\" first}"; }

db_host() { echo "$APP_DB_URL" | sed -E 's#^jdbc:postgresql://([^:/]+).*#\1#'; }

add_host_flag() {
  local host ip
  host="$(db_host)"
  ip="$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}')" || true
  if [ -n "$ip" ]; then echo "--add-host=$host:$ip"; fi
}

wait_healthy() {  # $1 = host port
  for _ in $(seq 1 120); do
    if curl -fsS "http://localhost:$1/actuator/health" 2>/dev/null | grep -q '"UP"'; then return 0; fi
    sleep 1
  done
  echo "instance on port $1 did not become healthy; last logs:" >&2
  docker logs --tail 40 "$([ "$1" = 8081 ] && echo app-a || echo app-b)" >&2 || true
  return 1
}

run_app() {  # $1 = name, $2 = mode
  local name="$1" mode="$2"
  if docker container inspect "$name" >/dev/null 2>&1; then
    docker stop -t 20 "$name" >/dev/null || true   # graceful: in-flight requests finish
    docker rm "$name" >/dev/null
  fi
  # Credentials are passed by name (-e VAR), so they never appear on a command line.
  DB_URL="$APP_DB_URL" DB_USER="$APP_DB_USER" DB_PASSWORD="$APP_DB_PASSWORD" APP_SCHEMA_MODE="$mode" \
  docker run -d --name "$name" --hostname "$name" \
    --network "$NET" --ip "${IP[$name]}" -p "${PORT[$name]}:8080" \
    $(add_host_flag) \
    --memory 700m -e JAVA_TOOL_OPTIONS="-Xmx400m" \
    -e DB_URL -e DB_USER -e DB_PASSWORD -e APP_SCHEMA_MODE \
    "$IMG" >/dev/null
  wait_healthy "${PORT[$name]}"
  echo "   $name serving $mode"
}

case "${1:-}" in
  build)
    docker build -q -t "$IMG" "$ROOT/app" >/dev/null
    echo "built $IMG"
    ;;
  up)
    need_db
    MODE="${2:?mode}"
    docker network inspect "$NET" >/dev/null 2>&1 || docker network create --subnet "$SUBNET" "$NET" >/dev/null
    run_app app-a "$MODE"
    run_app app-b "$MODE"
    docker rm -f zdm-lb >/dev/null 2>&1 || true
    docker run -d --name zdm-lb --network "$NET" -p "$LB_PORT:8080" \
      -v "$ROOT/infra/nginx.conf:/etc/nginx/nginx.conf:ro" "$NGINX_IMAGE" >/dev/null
    for _ in $(seq 1 30); do curl -fsS "http://localhost:$LB_PORT/customers/_mode" >/dev/null 2>&1 && break; sleep 1; done
    echo "== apps up in $MODE behind nginx on :$LB_PORT"
    ;;
  roll)
    need_db
    MODE="${2:?mode}"
    echo "== rolling app-a, then app-b, into $MODE"
    run_app app-a "$MODE"
    run_app app-b "$MODE"
    ;;
  down)
    docker rm -f app-a app-b zdm-lb >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    echo "== apps removed"
    ;;
  *)
    sed -n '2,13p' "$0"; exit 2 ;;
esac
