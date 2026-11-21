#!/usr/bin/env bash
# Check that every tool the PoC needs is installed and working.
#
#   bash scripts/setup/check-prereqs.sh            # local stack only
#   bash scripts/setup/check-prereqs.sh --aws      # also check AWS + Terraform
#
# Prints one line per check and a summary. Exit code 1 if anything REQUIRED fails.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK_AWS=0
[ "${1:-}" = "--aws" ] && CHECK_AWS=1

fail=0
ok()   { printf '  \033[32m[ok]\033[0m   %-26s %s\n' "$1" "$2"; }
bad()  { printf '  \033[31m[FAIL]\033[0m %-26s %s\n' "$1" "$2"; fail=1; }
warn() { printf '  \033[33m[warn]\033[0m %-26s %s\n' "$1" "$2"; }

echo "Repository: $ROOT"
case "$ROOT" in
  *OneDrive*) warn "repo location" "inside OneDrive: Docker file sharing and Files On-Demand can break mounts. Prefer e.g. C:/dev/liquibasepoc" ;;
  *" "*)      warn "repo location" "path contains spaces; scripts quote it, but a path without spaces avoids surprises" ;;
  *)          ok   "repo location" "$ROOT" ;;
esac

echo; echo "Required for the local stack"
if command -v git >/dev/null; then ok git "$(git --version)"; else bad git "install Git for Windows (includes Git Bash)"; fi

PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null && "$c" -c 'import sys; assert sys.version_info >= (3, 10)' 2>/dev/null; then PY="$c"; break; fi
done
if [ -n "$PY" ]; then ok python "$("$PY" --version 2>&1) ($PY)"; else bad python "need Python 3.10+ (the Microsoft Store stub does not count)"; fi

if command -v docker >/dev/null; then
  if docker info >/dev/null 2>&1; then
    ok docker "$(docker version --format 'client {{.Client.Version}}, engine {{.Server.Version}}')"
  else
    bad docker "installed but the engine is not running: start Docker Desktop"
  fi
  if docker compose version >/dev/null 2>&1; then ok "docker compose" "$(docker compose version --short)"; else bad "docker compose" "Docker Compose v2 missing"; fi
else
  bad docker "install Docker Desktop"
fi

if [ -d "$ROOT/.venv" ]; then ok "python venv" ".venv exists"; else warn "python venv" "not created yet: run bash scripts/setup/bootstrap.sh"; fi

echo; echo "Optional"
if command -v k6 >/dev/null; then ok k6 "$(k6 version 2>/dev/null | head -1)"; else warn k6 "needed only for load/availability runs"; fi
if command -v java >/dev/null; then ok java "$(java -version 2>&1 | head -1)"; else warn java "not needed: the app builds inside Docker; CI runs the Java tests"; fi
if command -v mvn >/dev/null; then ok maven "$(mvn -v 2>/dev/null | head -1)"; else warn maven "not needed (same reason as java)"; fi

if [ $CHECK_AWS -eq 1 ]; then
  echo; echo "Required for AWS RDS"
  if command -v terraform >/dev/null; then ok terraform "$(terraform version | head -1)"; else bad terraform "install Terraform"; fi
  if command -v aws >/dev/null; then
    ok "aws cli" "$(aws --version 2>&1)"
    if ident=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null); then
      ok "aws credentials" "$ident (region: $(aws configure get region || echo 'not set'))"
    else
      bad "aws credentials" "not configured or expired: run aws configure"
    fi
  else
    bad "aws cli" "install AWS CLI v2"
  fi
fi

echo
if [ $fail -eq 0 ]; then echo "All required checks passed."; else echo "Fix the FAIL lines above, then run this again."; fi
exit $fail
