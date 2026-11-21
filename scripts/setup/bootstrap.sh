#!/usr/bin/env bash
# One-time project setup: Python virtual environment, dependencies, first checks.
# Safe to re-run.
#
#   bash scripts/setup/bootstrap.sh
#
# Afterwards, in every new Git Bash window:
#   source .venv/Scripts/activate      (Windows)
#   source .venv/bin/activate          (macOS / Linux)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null && "$c" -c 'import sys; assert sys.version_info >= (3, 10)' 2>/dev/null; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "Python 3.10+ not found. Run scripts/setup/install-prereqs.ps1 first." >&2; exit 1; }

echo "== 1/4 virtual environment (.venv)"
[ -d .venv ] || "$PY" -m venv .venv
if [ -f .venv/Scripts/python.exe ]; then VPY=.venv/Scripts/python; else VPY=.venv/bin/python; fi

echo "== 2/4 Python packages"
"$VPY" -m pip install -q --upgrade pip
"$VPY" -m pip install -q -r tools/phase-linter/requirements.txt -r experiments/requirements.txt

echo "== 3/4 shell scripts executable + LF line endings"
chmod +x scripts/*.sh scripts/setup/*.sh 2>/dev/null || true
if grep -l $'\r' scripts/*.sh scripts/setup/*.sh >/dev/null 2>&1; then
  echo "   WARNING: some .sh files have Windows (CRLF) line endings and will fail in bash."
  echo "   Fix: git rm --cached -r . -q && git reset --hard   (re-checks out using .gitattributes)"
fi

echo "== 4/4 first check: phase linter + its tests (no database needed)"
"$VPY" tools/phase-linter/phase_lint.py db/changelog/db.changelog-master.yaml
(cd tools/phase-linter && "../../$VPY" -m pytest -q)

echo
echo "Bootstrap done. Activate the environment in this shell with:"
if [ -f .venv/Scripts/activate ]; then echo "   source .venv/Scripts/activate"; else echo "   source .venv/bin/activate"; fi
