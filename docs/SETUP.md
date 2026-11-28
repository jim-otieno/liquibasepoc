# Setting up and owning the PoC

This guide takes you from an empty Windows machine to running the PoC end to end, first locally, then on AWS RDS, then in GitHub CI. Then it shows you how to change it.

Do the parts in order. Each step ends with a **✅ Check**. Don't move on until the check passes; most setup problems come from skipping one.

| Part | You get | Needs AWS? | Time |
|---|---|---|---|
| [A. Prepare your machine](#part-a--prepare-your-machine-once) | Tools installed, repo cloned, Python env ready | No | 30–45 min |
| [B. Run locally](#part-b--run-the-poc-locally-no-cloud) | Full migration running against PostgreSQL in Docker | No | 15 min |
| [C. Run on AWS RDS](#part-c--run-on-aws-rds) | The same migration against a managed cloud database | Yes | 20 min |
| [D. GitHub CI](#part-d--github-ci) | Every push to `main` runs the phases on RDS | Yes | 15 min |
| [E. How it works](#part-e--how-the-poc-works) | A mental model of every file | No | reading |
| [F. Make it yours](#part-f--make-it-yours-exercises) | Exercises: add a migration, break a rule, add a lint rule | No | 1–2 h |
| [G. Troubleshooting](#part-g--troubleshooting) | Fixes for every problem hit so far | — | — |
| [H. Jenkins on AWS](#part-h--jenkins-on-aws) | A Jenkins server that runs the phases on RDS, with an approval gate | Yes | 30 min |

**Two shells, one rule.**
- Blocks marked `powershell` run in PowerShell.
- Blocks marked `bash` run in **Git Bash**. All the `.sh` scripts are bash, so never run them from PowerShell or CMD.
- To open Git Bash in the repo, right-click the repo folder in Explorer and choose **Open Git Bash here**, or run `cd /c/dev/liquibasepoc` inside Git Bash.

---

## Part A — Prepare your machine (once)

### A1. Put the repo outside OneDrive

Docker Desktop has trouble mounting files from OneDrive: Files On-Demand placeholders, and paths with spaces such as `Liquibase PoC`. Clone a fresh copy to a short path with no spaces:

```powershell
New-Item -ItemType Directory -Force C:\dev
```

```powershell
git clone https://github.com/jim-otieno/liquibasepoc.git C:\dev\liquibasepoc
```

From here on, work in `C:\dev\liquibasepoc`. You can delete the OneDrive copy once you've pushed anything you need from it.

✅ **Check:** `C:\dev\liquibasepoc\README.md` exists.

### A2. Install the tools

From the repo folder in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File C:\dev\liquibasepoc\scripts\setup\install-prereqs.ps1
```

The script uses `winget`, skips anything already installed, and installs:

| Tool | Why the PoC needs it |
|---|---|
| Git (with Git Bash) | source control; runs the `.sh` scripts |
| Python 3.12 | phase linter, experiment scripts, analysis |
| Docker Desktop | runs Liquibase, PostgreSQL, the app, nginx, Prometheus, Grafana |
| k6 | availability probe and load during migrations |
| Terraform | creates the AWS RDS instance |
| AWS CLI v2 | AWS access (Terraform credentials, database password) |

Add `-IncludeOptional` to also install Java 21 and the GitHub CLI. You don't need Java: the app builds inside Docker, and CI runs the Java tests.

Then **close every terminal and open a new one**, so the new tools are on your PATH.

### A3. Start Docker Desktop

Open Docker Desktop from the Start menu. The first time, accept the terms and let it finish setting up WSL 2. Wait until the bottom-left status says **Engine running**.

✅ **Check (PowerShell):** `docker run --rm hello-world` prints "Hello from Docker!".

### A4. Check everything

In **Git Bash**, from the repo folder:

```bash
bash scripts/setup/check-prereqs.sh
```

✅ **Check:** the script ends with "All required checks passed." `[warn]` lines for k6, Java or Maven are fine. Any `[FAIL]` line tells you what to fix.

### A5. Bootstrap the project

```bash
bash scripts/setup/bootstrap.sh
```

This script:
1. creates a Python virtual environment in `.venv`;
2. installs `PyYAML`, `pytest`, `psycopg`, `oracledb`, `pandas` and `scipy` into it;
3. makes the scripts executable;
4. runs the phase linter and its tests. Neither needs a database.

✅ **Check:** the output contains `phase_lint: 9 changesets, 0 error(s)` and `9 passed`.

Every time you open a new Git Bash window for this project, activate the environment first:

```bash
cd /c/dev/liquibasepoc && source .venv/Scripts/activate
```

Your prompt now starts with `(.venv)`.

---

## Part B — Run the PoC locally (no cloud)

### B1. Start PostgreSQL

```bash
docker compose -f infra/docker-compose.yml up -d postgres
```

✅ **Check:** `docker compose -f infra/docker-compose.yml ps` shows `postgres` as `healthy` (this can take about 10 seconds).

### B2. Point your shell at it

```bash
eval "$(scripts/local-env.sh)"
```

This sets the variables every script reads (`DB_*` for the Python scripts, `LB_*` for Liquibase). It's worth knowing why there are two addresses for one database:
- Python runs on your machine, so it connects to `localhost:5432`.
- Liquibase runs in a container on the compose network, so it connects to `postgres:5432`.

✅ **Check:** `echo $LB_URL` prints `jdbc:postgresql://postgres:5432/poc`.

### B3. Run the guided walkthrough

```bash
scripts/walkthrough.sh
```

This is the most important step in the guide, so run it slowly. Before each step it explains what is about to happen and why, then waits for Enter. After each step it prints the database's columns, constraints, indexes and Liquibase history, so you can **see** the effect. It walks through:

1. **Lint:** the two invariants, phase discipline and lock safety.
2. **Baseline:** the `customer` table and 20,000 rows. This is app v1's world.
3. **Expand:** adds the nullable `full_name` column and an index built concurrently.
4. **Rollback demo:** undoes the expand phase, then re-applies it.
5. **Migrate gate:** refuses to run before the backfill. That refusal is intended.
6. **Backfill:** copies `customer_name` into `full_name` in batches of 5,000 rows.
7. **Migrate:** the gate now passes, and integrity is verified.
8. **Harden:** adds the constraint `NOT VALID`, then validates it, so watch the marker disappear. It also makes the old column nullable.
9. **Contract:** drops the old column. This is the one irreversible step.

The walkthrough creates its own throwaway database, `walk_<timestamp>`, and drops it at the end. Add `--keep` to leave the database in place for exploring, or `--no-pause` to run straight through.

✅ **Check:** it ends with "integrity check passed" and the Liquibase history.

### B4. (Optional) Add the app and live traffic

This shows the *zero-downtime* part: two app instances behind nginx, rolled one at a time through modes v1 → v4 while k6 sends traffic.

```bash
docker compose -f infra/docker-compose.yml up -d --build
```

The first build downloads Maven dependencies and takes about 5 minutes. Then, in a second Git Bash window (with the venv activated and `local-env` loaded), start the probe:

```bash
k6 run -e DURATION=10m load/k6-availability.js
```

In the first window, run the walkthrough with the app:

```bash
scripts/walkthrough.sh --with-app
```

✅ **Check:** http://localhost:8080/customers/_mode shows the current app mode, and k6's summary at the end reports `zdm_available` close to 100%. Grafana is at http://localhost:3000 and Prometheus at http://localhost:9090.

Stop everything when you're done:

```bash
docker compose -f infra/docker-compose.yml down
```

Add `-v` to also delete the database volume.

---

## Part C — Run on AWS RDS

RDS costs money while it exists: about USD 13–16 a month for `db.t3.micro`, or nothing in the free tier. Part C ends with how to destroy it.

### C1. Give your machine AWS access

Create an access key for your IAM user in the AWS console (**IAM → Users → your user → Security credentials → Create access key → Command Line Interface**). Then run:

```powershell
aws configure
```

Enter the key ID, the secret, region `us-east-1`, and output `json`. The keys are saved in `%USERPROFILE%\.aws\credentials`. **Never commit them or paste them into chat.**

✅ **Check (Git Bash):** `bash scripts/setup/check-prereqs.sh --aws` shows `[ok] aws credentials` with your user's ARN.

### C2. Create the database with Terraform

```bash
cd infra/aws
terraform init
terraform plan -out tfplan
```

Read the plan. It should show **8 to add**: the RDS instance, its parameter group, subnet group, security group and your-IP rule, plus the GitHub OIDC provider, CI role and role policy.

If the OIDC provider already exists in your account (for example from another project), Terraform's `apply` will fail on it. In that case, ask for help importing it rather than deleting the existing one.

```bash
terraform apply tfplan
cd ../..
```

Creating the instance takes about 10 minutes.

✅ **Check:** `terraform -chdir=infra/aws output endpoint` prints `liquibase-poc.….rds.amazonaws.com`.

### C3. Point your shell at RDS and run the walkthrough

```bash
eval "$(scripts/rds-env.sh)"
scripts/walkthrough.sh
```

`rds-env.sh` reads the endpoint from Terraform and fetches the master password from Secrets Manager into your shell only; it's never written to a file. Connections use TLS.

✅ **Check:** the same output as in B3, with `server:` showing the RDS endpoint.

### C4. Living with RDS

- **Your IP changed** (home or office, or your router got a new address) and connections time out: run `terraform -chdir=infra/aws apply` to update the firewall rule to your new IP.
- **For real experiment runs**, use a non-burstable size, because `t3` CPU credits make latency noisy: `terraform -chdir=infra/aws apply -var instance_class=db.m7g.large`
- **Stop all charges when you aren't experimenting:**

```bash
terraform -chdir=infra/aws destroy
```

`apply` brings it back. The database contents are lost on destroy, which is fine: every run seeds its own data.

---

## Part D — GitHub CI

`.github/workflows/ci.yml` has three jobs:

| Job | Runs on | Proves |
|---|---|---|
| `phase-linter` | every push and PR | changelog obeys the phase and lock-safety rules |
| `compatibility-matrix` | every push and PR | each phase works with both adjacent app versions (Testcontainers) |
| `phases-on-rds` | pushes to `main` only | all phases apply to the real RDS instance, plus rollback and the migrate gate |

### D1. How CI gets into AWS without stored keys

CI never sees an AWS access key:
1. GitHub gives the job a short-lived **OIDC token** that says "I'm `main` of repository X".
2. AWS trusts that token only for the role `liquibase-poc-github-ci`.
3. That role can only look up this one database, read its password, and open or close its firewall.

Each run then opens port 5432 to the runner's IP, creates a throwaway `ci_<run>` database, runs the phases, drops the database and closes the port.

### D2. If you use your own repository (fork, rename or new owner)

The role trusts one specific repository, by name **and** by numeric IDs. GitHub now puts the IDs in the token. Find your repo's IDs, replacing `OWNER/REPO`:

```bash
curl -s https://api.github.com/repos/OWNER/REPO | python -c "import sys,json;r=json.load(sys.stdin);print(f\"{r['owner']['login']}@{r['owner']['id']}/{r['name']}@{r['id']}\")"
```

Apply with your values:

```bash
terraform -chdir=infra/aws apply -var github_repo=OWNER/REPO -var github_repo_with_ids=OWNER@123/REPO@456
```

To avoid typing them every time, put both values in `infra/aws/terraform.tfvars`.

### D3. Tell GitHub which role to use

```bash
terraform -chdir=infra/aws output -raw github_ci_role_arn
```

In GitHub, go to the repo's **Settings → Secrets and variables → Actions**. On the **Variables** tab (or the Secrets tab; both work), add `AWS_ROLE_ARN` with that value. Add it at **repository** level, not under an Environment.

### D4. Run it

Push anything to `main`. To start a run without changes:

```bash
git commit --allow-empty -m "CI: run" && git push
```

✅ **Check:** on the repo's **Actions** tab, all three jobs are green. If `phases-on-rds` fails, its annotation says exactly why (see Part G).

---

## Part E — How the PoC works

### The core idea in one picture

```
            schema (Liquibase label)                     app mode (feature flag)
baseline    customer_name NOT NULL                       v1 OLD_ONLY
expand      + full_name (nullable), index CONCURRENTLY   v2 DUAL_WRITE_READ_OLD
migrate     backfill done? (gate)                        v2 (shadow-reads compare old/new)
harden      CHECK full_name NOT NULL: NOT VALID→VALIDATE v3 DUAL_WRITE_READ_NEW → v4 NEW_ONLY
            customer_name becomes nullable
contract    DROP customer_name   (irreversible)          v4
```

**Compatibility invariant:** after every phase, the schema works for the app version before it *and* the one after it. That's why a rolling deploy never breaks.

**Lock-safety invariant:** every DDL statement is either non-blocking or gives up after 2 seconds and retries, so it never queues in front of user traffic.

### What happens when you run `scripts/deploy-phase.sh expand`

```
deploy-phase.sh expand
  ├─ liquibase.sh tag pre-expand-<build>          ← rollback point
  └─ liquibase.sh update --label-filter=expand    ← retried with back-off on lock timeout
        └─ docker run liquibase/liquibase:4.29.2  (mounts db/changelog, connects to $LB_URL)
              └─ reads db.changelog-master.yaml → includes every release file
                 → runs only changesets labelled 'expand' that haven't run yet
                 → records each one in DATABASECHANGELOG
```

### File map: where to look when you want to change something

| You want to… | Look at |
|---|---|
| Add or change a migration | `db/changelog/releases/<release>/<NN-phase>.yaml`, and include it in `db/changelog/db.changelog-master.yaml` |
| Change what the linter allows | `tools/phase-linter/phase_lint.py` (rules in `lint_changeset`), with tests in `test_phase_lint.py` |
| Change how a phase is deployed (tag, retries) | `scripts/deploy-phase.sh` |
| Change the Liquibase version or how it's run | `scripts/liquibase.sh` (`LIQUIBASE_IMAGE`) |
| Change the app's dual-write behaviour | `app/src/main/java/org/research/zdm/CustomerRepository.java` and `SchemaMode.java` |
| Change the compatibility test | `app/src/test/java/org/research/zdm/CompatibilityMatrixTest.java` |
| Change backfill speed or batching | `experiments/backfill.py` (`--batch`, `--sleep-ms`) |
| Change lock measurement | `experiments/lock_sampler.py` |
| Change load or what counts as "unavailable" | `load/k6-availability.js` |
| Change the experiment design (arms, factors) | `experiments/run_matrix.py` (`FACTORS`), `experiments/arms.json`, `scripts/run-arm.sh` |
| Change statistics | `analysis/analyze.py` |
| Change the local stack | `infra/docker-compose.yml`, `infra/nginx.conf`, `infra/prometheus.yml` |
| Change the AWS database (size, version, access) | `infra/aws/variables.tf`, `infra/aws/main.tf` |
| Change CI | `.github/workflows/ci.yml` |
| Change Jenkins or Azure DevOps | `pipelines/Jenkinsfile.rds` (RDS), `pipelines/Jenkinsfile` (full local stack), `pipelines/azure-pipelines.yml` |
| Change the Jenkins server | `infra/jenkins/main.tf`, `infra/jenkins/user-data.sh` |

---

## Part F — Make it yours (exercises)

Do these locally (Part B environment). Each takes 10–30 minutes and teaches one part of the system.

### F1. Add your own expand/contract migration

Goal: add a `phone` column the safe way. This is the "add column" change type, C1 in the research design.

1. Create `db/changelog/releases/1.3-add-phone/01-expand.yaml`:

    ```yaml
    databaseChangeLog:
      - changeSet:
          id: phone-01-add-column
          author: you
          labels: expand
          preConditions:
            - onFail: MARK_RAN
            - not:
                - columnExists: { tableName: customer, columnName: phone }
          changes:
            - sql: { dbms: postgresql, sql: "SET lock_timeout = '2s'" }
            - sql: { dbms: oracle, sql: "ALTER SESSION SET ddl_lock_timeout = 2" }
            - addColumn:
                tableName: customer
                columns:
                  - column: { name: phone, type: VARCHAR(32) }
          rollback:
            - dropColumn: { tableName: customer, columnName: phone }
    ```

2. Include it at the end of `db/changelog/db.changelog-master.yaml`:

    ```yaml
      - include:
          file: releases/1.3-add-phone/01-expand.yaml
          relativeToChangelogFile: true
    ```

3. Lint it: `python tools/phase-linter/phase_lint.py db/changelog/db.changelog-master.yaml`
4. Run `scripts/walkthrough.sh --no-pause --keep`, and confirm `phone` appears after the expand step.

### F2. Break the rules and watch the linter catch it

In your new changeset, try each of these one at a time, re-running the linter after each:
- Delete the `SET lock_timeout` line. The linter reports `lock-timeout`: DDL could queue behind a long query.
- Change `labels: expand` to `labels: experiment`. The linter reports `phase-label`.
- Add `- dropColumn: { tableName: customer, columnName: email }` under `changes`. The linter reports `destructive-outside-contract`.
- Replace `addColumn` with `renameColumn`. The linter reports `breaking-change`.

Restore the file when you're done.

### F3. Add a lint rule

Example rule: *"`modifyDataType` and `ALTER COLUMN … TYPE` are already banned; also ban `addDefaultValue` outside harden, because on some databases it rewrites the table."*

1. In `tools/phase-linter/phase_lint.py`, inside `lint_changeset`, after the destructive checks, add:

    ```python
    if phase != "harden":
        for name, _ in changes:
            if name == "addDefaultValue":
                add("ERROR", "default-outside-harden", "addDefaultValue belongs in the harden phase")
    ```

2. Add a test to `test_phase_lint.py`, copying `test_drop_column_outside_contract` as a template.
3. Run `cd tools/phase-linter && python -m pytest -q`.

### F4. Change the app's behaviour

Open `SchemaMode.java` and `CustomerRepository.java`, read the table in the `SchemaMode` comment, then trace how `create()` picks which columns to write. Try changing the shadow-read so it also runs in `DUAL_WRITE_READ_NEW`. Push to a branch and let the `compatibility-matrix` CI job tell you if you broke the compatibility invariant.

### F5. Implement the next experiment arm

`scripts/run-arm.sh` has `TODO` arms (`naive`, `trigger`, `cdc`). The `naive` arm is the easiest: a single changeset with `renameColumn` (the linter will flag it, which is the point of the baseline). Write it in a separate changelog file used only by that arm, then deploy it while k6 runs and compare `zdm_available` with the dual-write arm.

---

## Part G — Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `bash: scripts/x.sh: /usr/bin/env: bad interpreter` or `$'\r': command not found` | The file has Windows CRLF line endings | `git rm --cached -r . -q && git reset --hard` (`.gitattributes` forces LF on re-checkout) |
| `python: command not found`, or Python opens the Microsoft Store | Venv not activated, or the Store stub is first on PATH | `source .venv/Scripts/activate`; otherwise turn off the `python.exe` alias under **Settings → Apps → Advanced app settings → App execution aliases** |
| `Cannot connect to the Docker daemon` | Docker Desktop isn't running | Start it and wait for "Engine running" |
| Liquibase: `Connection refused` to `localhost:5432` | Liquibase runs in a container, where `localhost` means the container itself | `eval "$(scripts/local-env.sh)"`, so Liquibase uses `postgres:5432` on the compose network |
| Liquibase: `network liquibase-poc_default not found` | The compose stack isn't running | `docker compose -f infra/docker-compose.yml up -d postgres` |
| Liquibase: `changelog file ... not found` / mount errors | Repo inside OneDrive or a path Docker can't share | Clone to `C:\dev\liquibasepoc` (A1) |
| Deploy prints `lock timeout: DDL yielded to traffic; retrying` | Something holds a lock on `customer` (for example a long query) | Working as designed; it retries with back-off. If it gives up after 5 tries, find the blocker with `experiments/lock_sampler.py` |
| `Backfill incomplete - rows with full_name IS NULL remain` | You ran the migrate phase before the backfill | Run `python experiments/backfill.py`, then the migrate phase again |
| RDS connection times out | Your public IP changed | `terraform -chdir=infra/aws apply` |
| `rds-env.sh`: `ExpiredToken` / `InvalidClientTokenId` | AWS keys wrong or expired | `aws configure`, then `aws sts get-caller-identity` |
| CI `compatibility-matrix`: `status code: 429, Too Many Requests` | Maven Central rate-limited the runner | Already retried automatically; if it still fails, re-run the job |
| CI: `Could not find a valid Docker environment` | Testcontainers too old for the runner's Docker | Already fixed (Testcontainers 1.21.3 + API pin); keep those lines when editing |
| CI `phases-on-rds`: `AWS_ROLE_ARN not visible` | Value saved under an Environment, or with a different name | Add it at repository level (D3) |
| CI `phases-on-rds`: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Role trusts a different repo name or IDs | Look up the `sub` CloudTrail recorded (below), then fix it via D2 |
| `git push` over SSH: `Permission denied (publickey)` | SSH key not added to GitHub | Use the HTTPS remote, or add `~/.ssh/id_ed25519.pub` under GitHub **Settings → SSH and GPG keys** |

To see exactly which identity GitHub presented when the AWS role was denied:

```bash
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity --max-results 3 --query "Events[].CloudTrailEvent" --output text | grep -o '"userName":"[^"]*"'
```

---

## Part H — Jenkins on AWS

An alternative to GitHub CI: a Jenkins server on EC2 runs the same phases against RDS, and pauses for a human before the irreversible contract phase.

[infra/jenkins](../infra/jenkins) creates one `t3.micro` (Amazon Linux 2023, Jenkins LTS, Docker, Python 3.11, 2 GB swap). Port 8080 is open only to your IP. There is no SSH: you get a shell through SSM Session Manager. The instance role can read the RDS password from Secrets Manager, and the RDS security group admits the instance from inside the VPC, so the pipeline needs no Jenkins credentials and no per-run port opening.

### H1. Create the server

Needs Part C done (the RDS stack must exist).

```bash
terraform -chdir=infra/jenkins init
terraform -chdir=infra/jenkins apply          # ~1 min, then Jenkins installs itself for 5-10 min
bash scripts/setup/jenkins-unlock.sh          # waits, then prints the URL and unlock password
```

Run these in **Git Bash**. PowerShell has no `bash` command; from PowerShell use:

```powershell
& "C:\Program Files\Git\bin\bash.exe" scripts/setup/jenkins-unlock.sh
```

✅ **Check:** the URL opens a Jenkins "Unlock Jenkins" page.

### H2. First-time Jenkins setup

1. Paste the unlock password.
2. Choose **Install suggested plugins** (a few minutes on a small instance).
3. Create your admin user. Keep the Jenkins URL it proposes.

### H3. Create the pipeline job

1. **New Item** → name `liquibase-phases-rds` → **Pipeline** → OK.
2. Under **Pipeline**: Definition **Pipeline script from SCM**, SCM **Git**, Repository URL `https://github.com/jim-otieno/liquibasepoc.git`, Branch `*/main`, Script Path `pipelines/Jenkinsfile.rds`.
3. Save, then **Build Now**. The first build only registers the parameters; from then on use **Build with Parameters**.

Each build creates a throwaway database `jenkins_<build>`, runs baseline → expand (plus a rollback test) → migrate gate → backfill → migrate → harden, waits for you to click **Run contract**, runs contract, and then drops the database.

✅ **Check:** the build's **Stages** view is all green, and `Contract` shows the `history` table.

### H4. Living with the server

- Your public IP changed and the UI no longer loads: `terraform -chdir=infra/jenkins apply` (it re-detects the IP).
- Shell on the server: `aws ssm start-session --target "$(terraform -chdir=infra/jenkins output -raw instance_id)"` (needs the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)).
- Install log: `sudo tail -50 /var/log/jenkins-bootstrap.log` on the server.
- Slow builds: 1 GB is tight. `terraform -chdir=infra/jenkins apply -var instance_type=t3.small` doubles the memory and keeps the Jenkins data, because the instance is stopped and resized in place.
- Stop paying for it: `terraform -chdir=infra/jenkins destroy`. RDS is untouched. Jenkins configuration and jobs are lost, so recreating the server means doing H2 and H3 again.
- The UI is plain HTTP, limited to your IP. Put it behind HTTPS before opening it any wider.

---

## Daily cheat sheet

```bash
cd /c/dev/liquibasepoc && source .venv/Scripts/activate

# local
docker compose -f infra/docker-compose.yml up -d postgres
eval "$(scripts/local-env.sh)"

# or AWS
eval "$(scripts/rds-env.sh)"

scripts/walkthrough.sh --no-pause                     # whole migration, throwaway DB
scripts/deploy-phase.sh <phase>                       # one phase against $LB_URL
scripts/liquibase.sh status --verbose                 # what's pending
scripts/liquibase.sh history                          # what has run
python experiments/show_schema.py                     # what the table looks like now
python tools/phase-linter/phase_lint.py db/changelog/db.changelog-master.yaml

terraform -chdir=infra/jenkins destroy                # stop Jenkins charges (first: it uses the RDS stack)
terraform -chdir=infra/aws destroy                    # stop AWS charges
```
