# Lock-Free by Construction: Liquibase Expand/Contract PoC

Proof of concept for the research project *"Phase-structured expand-and-contract
schema migrations with Liquibase for zero-downtime continuous deployment"*.

> **New here? Start with [docs/SETUP.md](docs/SETUP.md).** It's a step-by-step
> guide from an empty Windows machine to running the PoC locally, on AWS RDS
> and in CI, plus exercises for changing it.

Liquibase changesets are split into backward-compatible **phases**. The
application **dual-writes** behind feature flags. A **phase linter** and a
**compatibility-matrix test** enforce the two invariants:

- **Compatibility:** after every phase, the schema serves both adjacent
  application versions.
- **Lock safety:** every DDL statement is non-blocking or bounded by a lock timeout.

| Phase | Liquibase label | Schema change (example C3: rename `customer_name` → `full_name`) | App mode after the phase |
|---|---|---|---|
| 1 Expand | `expand` | add nullable `full_name` | v2 `DUAL_WRITE_READ_OLD` |
| 2 Migrate | `migrate` | batched backfill (external job); gate checks no NULLs | v2 |
| 3 Harden | `harden` | `CHECK … NOT VALID` → `VALIDATE`; old column nullable | v3 `DUAL_WRITE_READ_NEW` → v4 `NEW_ONLY` |
| 4 Contract | `contract` | drop `customer_name` (**irreversible**, approval gate) | v4 |

## Repository layout

```
app/                    Spring Boot service; SchemaMode = feature-flagged dual-write
  src/test/.../CompatibilityMatrixTest.java   phases x app modes on Testcontainers PostgreSQL
db/changelog/           master changelog + releases/<migration>/<phase>.yaml
tools/phase-linter/     lock-safety and phase-discipline linter (+ pytest suite)
experiments/            seed, backfill, lock sampler, long reader, integrity gate, run matrix
load/                   k6 availability probe
analysis/               Kruskal-Wallis, Mann-Whitney (Holm), Cliff's delta, A12
infra/                  docker compose: PostgreSQL, Oracle 23ai Free, 2 app instances + nginx, Prometheus, Grafana
scripts/                liquibase.sh (Docker), deploy-phase.sh (tag + retry on lock timeout),
                        rolling-deploy.sh, run-arm.sh
pipelines/              Jenkinsfile, azure-pipelines.yml
.github/workflows/      GitHub Actions CI
```

## Quick start (PostgreSQL)

Prerequisites: Docker Desktop, Python 3.10+, Git Bash (Windows) or any POSIX
shell, and [k6](https://k6.io) for load runs. Java 21 + Maven only if you build
the app outside Docker.

```bash
# 1. Lint the changelog (no database needed)
python -m venv .venv && . .venv/Scripts/activate      # Linux/macOS: . .venv/bin/activate
pip install -r tools/phase-linter/requirements.txt -r experiments/requirements.txt
python tools/phase-linter/phase_lint.py db/changelog/db.changelog-master.yaml
python -m pytest -q tools/phase-linter

# 2. Start the stack
docker compose -f infra/docker-compose.yml up -d --build

# 3. Liquibase runs inside the compose network
export LB_NETWORK=liquibase-poc_default
export LB_URL=jdbc:postgresql://postgres:5432/poc

# 4. Baseline + data, then walk through the phases
scripts/deploy-phase.sh baseline
python experiments/seed_data.py --rows 1000000
scripts/deploy-phase.sh expand
scripts/rolling-deploy.sh DUAL_WRITE_READ_OLD
python experiments/backfill.py
scripts/deploy-phase.sh migrate
python experiments/verify_integrity.py
scripts/deploy-phase.sh harden
scripts/rolling-deploy.sh DUAL_WRITE_READ_NEW
scripts/rolling-deploy.sh NEW_ONLY
scripts/deploy-phase.sh contract      # irreversible
```

In a second terminal during the phases, run the probes:

```bash
python experiments/lock_sampler.py --out results/manual/locks.csv
k6 run -e MAX_ID=1000000 load/k6-availability.js
```

Oracle: `docker compose -f infra/docker-compose.yml --profile oracle up -d`, then
`LB_URL=jdbc:oracle:thin:@oracle:1521/FREEPDB1`, `DB_KIND=oracle`, `DB_PORT=1521`,
`DB_NAME=FREEPDB1`, and `APP_DB_URL=jdbc:oracle:thin:@oracle:1521/FREEPDB1` for the apps.
The lock sampler needs `SELECT_CATALOG_ROLE` on the Oracle user.

## AWS RDS target

[infra/aws](infra/aws) creates an RDS PostgreSQL 16 instance (`db.t3.micro`,
single-AZ, TLS forced, `log_lock_waits` on). The database is reachable only
from your current public IP. The master password lives in Secrets Manager, never in
git or Terraform state.

```bash
cd infra/aws && terraform init && terraform apply     # ~10 min; billable while it exists
terraform output github_ci_role_arn                   # -> GitHub repo variable AWS_ROLE_ARN
cd ../.. && eval "$(scripts/rds-env.sh)"              # point every script at RDS
scripts/deploy-phase.sh baseline                      # ...then the phases as above
terraform -chdir=infra/aws destroy                    # stop all charges
```

The `phases-on-rds` CI job runs on pushes to `main` once the `AWS_ROLE_ARN`
repository variable is set. It assumes the role via GitHub OIDC (no stored AWS
keys; pull requests and forks cannot assume it). It opens port 5432 to the
runner's IP, works in a throwaway `ci_<run>` database, then drops the database
and closes the port. Pull requests still run the linter and the Testcontainers
compatibility test.

`db.t3.micro` is burstable: CPU credits make timed latency measurements noisy.
Use `-var instance_class=db.m7g.large` (or similar) for the real experiment
runs, and destroy the instance between sessions.

## Experiment

```bash
python experiments/run_matrix.py --plan-only                       # randomised plan -> results/plan.csv
python experiments/run_matrix.py --execute --replicates 3 \
       --only dbms=postgresql --only arm=A3-app-dual-write,A4-enforced --only change=C3-rename-column
python analysis/analyze.py results/summary.csv --metric blocked_session_s
```

Arms: A1 naive · A2 trigger sync · A3 app dual-write · A4 A3 + linter + lock timeouts · A5 CDC blue-green.

## Status

| Component | State |
|---|---|
| Phased changelogs C3 (rename) and C6 (index), PostgreSQL + Oracle | written; PostgreSQL path exercised by CI |
| Phase linter + tests | working locally |
| Compatibility-matrix test | written; runs in CI (needs Docker) |
| Pipelines: GitHub Actions, Jenkins, Azure DevOps | written; not yet run on a server |
| Arms A3/A4 for C3 on PostgreSQL | implemented in `scripts/run-arm.sh` |
| Arms A1, A2, A5; changes C1, C2, C4, C5, C7; Oracle runs | to do (work plan months 3–4) |
| `results/summary.csv` builder (from k6 + lock CSVs) | to do |
| Grafana dashboards | to do |

## Notes

- Liquibase image is pinned in `scripts/liquibase.sh` (`LIQUIBASE_IMAGE` overrides it).
  Liquibase 5.x moved the community edition to the Functional Source License. State the
  version and licence you used in the paper.
- The free Oracle images and any GoldenGate Free edition come with Oracle's own terms
  and resource caps. Check them before you report results.
