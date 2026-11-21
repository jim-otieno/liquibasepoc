#!/usr/bin/env python3
"""Phase linter for expand/contract Liquibase changelogs (YAML).

Enforces the two invariants of the phase model:

* Phase discipline - every changeset belongs to exactly one phase, and
  destructive or compatibility-breaking operations appear only where the
  phase model allows them.
* Lock safety - DDL uses non-blocking forms (CONCURRENTLY / ONLINE,
  NOT VALID / NOVALIDATE) and is bounded by a lock timeout.

Usage:
    python phase_lint.py db/changelog/db.changelog-master.yaml
    python phase_lint.py db/changelog/db.changelog-master.yaml --format json

Exit code 1 when any ERROR is found (use as a pull-request gate).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("phase_lint: PyYAML is required (pip install -r tools/phase-linter/requirements.txt)")

PHASES = {"baseline", "expand", "migrate", "migrate-inline", "harden", "contract"}

# Change types that never touch schema (no DDL lock to worry about).
NON_DDL_CHANGES = {"sql", "sqlFile", "tagDatabase", "insert", "update", "delete",
                   "loadData", "loadUpdateData", "empty", "output", "stop"}

# Break the N-1 application version: always replace with expand/contract.
BREAKING_CHANGES = {
    "renameColumn": "rename breaks the running N-1 version; add a new column, dual-write, backfill, then contract",
    "renameTable": "rename breaks the running N-1 version; create the new table and dual-write instead",
    "modifyDataType": "type change rewrites the table under an exclusive lock; add a new column and backfill instead",
}

# Only allowed in the contract phase.
DESTRUCTIVE_CHANGES = {"dropColumn", "dropTable", "dropView", "dropSequence"}

# Validate under an exclusive lock: use the two-step SQL form instead.
LOCKING_CHANGES = {
    "createIndex": "use sql: CREATE INDEX CONCURRENTLY (PostgreSQL, runInTransaction: false) / CREATE INDEX ... ONLINE (Oracle)",
    "addForeignKeyConstraint": "use sql: ADD CONSTRAINT ... NOT VALID then VALIDATE (PostgreSQL) / ENABLE NOVALIDATE then ENABLE VALIDATE (Oracle)",
    "addNotNullConstraint": "use a CHECK (col IS NOT NULL) constraint added NOT VALID / ENABLE NOVALIDATE, then validated",
    "addUniqueConstraint": "build a unique index CONCURRENTLY / ONLINE first, then attach the constraint USING INDEX",
}

DDL_SQL = re.compile(r"^\s*(ALTER\s+TABLE|CREATE|DROP|TRUNCATE|RENAME)\b", re.I)
VALIDATE_ONLY_SQL = re.compile(r"VALIDATE\s+CONSTRAINT|ENABLE\s+VALIDATE", re.I)
DESTRUCTIVE_SQL = re.compile(r"\bDROP\s+(COLUMN|TABLE)\b|\bSET\s+UNUSED\b|\bTRUNCATE\b", re.I)
CREATE_INDEX_SQL = re.compile(r"\bCREATE\s+(UNIQUE\s+)?INDEX\b", re.I)
ADD_CONSTRAINT_SQL = re.compile(r"\bADD\s+CONSTRAINT\b.*\b(CHECK|FOREIGN\s+KEY)\b", re.I | re.S)
RENAME_SQL = re.compile(r"\bRENAME\s+(COLUMN|TO)\b", re.I)
TYPE_CHANGE_SQL = re.compile(r"\bALTER\s+COLUMN\s+\w+\s+(SET\s+DATA\s+)?TYPE\b", re.I)
SET_NOT_NULL_SQL = re.compile(r"\bSET\s+NOT\s+NULL\b", re.I)


@dataclass
class Finding:
    severity: str  # ERROR | WARN
    rule: str
    file: str
    changeset: str
    message: str

    def __str__(self) -> str:
        return f"{self.severity:5} {self.rule:22} {self.file} [{self.changeset}] {self.message}"


@dataclass
class ChangeSet:
    file: Path
    data: dict

    @property
    def id(self) -> str:
        return str(self.data.get("id", "?"))

    @property
    def labels(self) -> list[str]:
        raw = self.data.get("labels")
        if raw is None:
            return []
        return [p.strip() for p in str(raw).split(",") if p.strip()]

    @property
    def changes(self) -> list[tuple[str, dict]]:
        out = []
        for item in self.data.get("changes") or []:
            if isinstance(item, dict):
                for name, body in item.items():
                    out.append((name, body if isinstance(body, dict) else {}))
            elif isinstance(item, str):
                out.append((item, {}))
        return out


# --------------------------------------------------------------------- loading
def load_changesets(path: Path, seen: set[Path] | None = None) -> list[ChangeSet]:
    seen = seen if seen is not None else set()
    path = path.resolve()
    if path in seen:
        return []
    seen.add(path)
    doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    result: list[ChangeSet] = []
    for entry in doc.get("databaseChangeLog") or []:
        if not isinstance(entry, dict):
            continue
        if "changeSet" in entry:
            result.append(ChangeSet(path, entry["changeSet"] or {}))
        elif "include" in entry:
            inc = entry["include"]
            base = path.parent if inc.get("relativeToChangelogFile") else Path.cwd()
            result.extend(load_changesets(base / inc["file"], seen))
        elif "includeAll" in entry:
            inc = entry["includeAll"]
            base = path.parent if inc.get("relativeToChangelogFile") else Path.cwd()
            for child in sorted((base / inc["path"]).rglob("*.y*ml")):
                result.extend(load_changesets(child, seen))
    return result


def sql_statements(changes: list[tuple[str, dict]]) -> list[tuple[str | None, str]]:
    """(dbms, statement) for every sql change; dbms None means 'all'."""
    out = []
    for name, body in changes:
        if name != "sql":
            continue
        text = str(body.get("sql", ""))
        dbms = body.get("dbms")
        if body.get("splitStatements", True):
            parts = [p for p in text.split(";") if p.strip()]
        else:
            parts = [text]
        out.extend((dbms, p) for p in parts)
    return out


# ----------------------------------------------------------------------- rules
def lint_changeset(cs: ChangeSet, root: Path) -> list[Finding]:
    f: list[Finding] = []
    rel = str(cs.file.relative_to(root)) if cs.file.is_relative_to(root) else str(cs.file)

    def add(sev: str, rule: str, msg: str) -> None:
        f.append(Finding(sev, rule, rel, cs.id, msg))

    labels = cs.labels
    if len(labels) != 1 or labels[0] not in PHASES:
        add("ERROR", "phase-label", f"needs exactly one phase label from {sorted(PHASES)}; found {labels or 'none'}")
        return f
    phase = labels[0]
    changes = cs.changes
    stmts = sql_statements(changes)

    if phase == "baseline":
        return f  # initial schema on an empty database: no live traffic to protect

    # Breaking operations - never allowed.
    for name, _ in changes:
        if name in BREAKING_CHANGES:
            add("ERROR", "breaking-change", f"{name}: {BREAKING_CHANGES[name]}")
    for _, s in stmts:
        if RENAME_SQL.search(s):
            add("ERROR", "breaking-change", "RENAME in SQL breaks the running N-1 version; use expand/contract")
        if TYPE_CHANGE_SQL.search(s):
            add("ERROR", "breaking-change", "ALTER COLUMN ... TYPE rewrites the table; add a new column and backfill")

    # Destructive operations - contract phase only.
    if phase != "contract":
        for name, _ in changes:
            if name in DESTRUCTIVE_CHANGES:
                add("ERROR", "destructive-outside-contract", f"{name} is only allowed under the 'contract' label")
        for _, s in stmts:
            if DESTRUCTIVE_SQL.search(s):
                add("ERROR", "destructive-outside-contract", "DROP/SET UNUSED/TRUNCATE is only allowed under the 'contract' label")

    # Locking forms.
    for name, _ in changes:
        if name in LOCKING_CHANGES:
            add("ERROR", "locking-ddl", f"{name}: {LOCKING_CHANGES[name]}")
    for dbms, s in stmts:
        if CREATE_INDEX_SQL.search(s):
            pg_ok = re.search(r"\bCONCURRENTLY\b", s, re.I)
            ora_ok = re.search(r"\bONLINE\b", s, re.I)
            if dbms == "postgresql" and not pg_ok:
                add("ERROR", "locking-ddl", "PostgreSQL CREATE INDEX without CONCURRENTLY blocks writes")
            elif dbms == "oracle" and not ora_ok:
                add("ERROR", "locking-ddl", "Oracle CREATE INDEX without ONLINE blocks DML")
            elif dbms is None and not (pg_ok or ora_ok):
                add("ERROR", "locking-ddl", "CREATE INDEX without CONCURRENTLY/ONLINE blocks writes")
            if pg_ok and cs.data.get("runInTransaction", True):
                add("ERROR", "concurrently-in-txn", "CREATE INDEX CONCURRENTLY needs runInTransaction: false")
        if ADD_CONSTRAINT_SQL.search(s) and not re.search(r"\bNOT\s+VALID\b|\bNOVALIDATE\b", s, re.I):
            add("ERROR", "locking-ddl", "ADD CONSTRAINT validates every row under lock; add it NOT VALID / ENABLE NOVALIDATE, validate separately")
        if SET_NOT_NULL_SQL.search(s):
            add("WARN", "set-not-null", "SET NOT NULL scans the table unless a validated CHECK (col IS NOT NULL) exists (PostgreSQL 12+)")

    # Lock timeout on any DDL.
    ddl_changes = [n for n, _ in changes if n not in NON_DDL_CHANGES]
    ddl_sql = [(d, s) for d, s in stmts
               if DDL_SQL.search(s) and not VALIDATE_ONLY_SQL.search(s) and not re.match(r"\s*ALTER\s+SESSION", s, re.I)]
    if ddl_changes or ddl_sql:
        all_sql = " ".join(s for _, s in stmts)
        dialects = {d for d, _ in ddl_sql} or {None}
        needs_pg = ddl_changes or "postgresql" in dialects or None in dialects
        needs_ora = ddl_changes or "oracle" in dialects or None in dialects
        if needs_pg and not re.search(r"lock_timeout", all_sql, re.I):
            add("ERROR", "lock-timeout", "DDL without SET lock_timeout (PostgreSQL) can queue behind a long query and block all traffic")
        if needs_ora and not re.search(r"ddl_lock_timeout", all_sql, re.I):
            add("ERROR", "lock-timeout", "DDL without ALTER SESSION SET ddl_lock_timeout (Oracle)")

    # Rollback and preconditions.
    only_tag = changes and all(n == "tagDatabase" for n, _ in changes)
    if "rollback" not in cs.data and not only_tag:
        add("ERROR", "rollback", "every changeset needs an explicit rollback (contract: one that fails on purpose)")
    if phase in {"expand", "contract"} and "preConditions" not in cs.data:
        add("WARN", "preconditions", "add preconditions so re-runs and partial failures are safe")
    if phase == "contract":
        pre = cs.data.get("preConditions") or []
        on_fail = next((p.get("onFail") for p in pre if isinstance(p, dict) and "onFail" in p), None)
        if on_fail != "HALT":
            add("WARN", "contract-guard", "contract preconditions should use onFail: HALT")
    return f


def lint(master: Path) -> list[Finding]:
    root = master.resolve().parent
    findings: list[Finding] = []
    seen_ids: set[str] = set()
    for cs in load_changesets(master):
        if cs.id in seen_ids:
            findings.append(Finding("ERROR", "duplicate-id", str(cs.file.name), cs.id, "changeset id used twice"))
        seen_ids.add(cs.id)
        findings.extend(lint_changeset(cs, root))
    return findings


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("changelog", type=Path, help="master changelog (YAML)")
    ap.add_argument("--format", choices=["text", "json"], default="text")
    ap.add_argument("--warnings-as-errors", action="store_true")
    args = ap.parse_args(argv)

    findings = lint(args.changelog)
    errors = [x for x in findings if x.severity == "ERROR" or (args.warnings_as_errors and x.severity == "WARN")]
    if args.format == "json":
        print(json.dumps([asdict(x) for x in findings], indent=2))
    else:
        for x in findings:
            print(x)
        n_cs = len(load_changesets(args.changelog))
        print(f"\nphase_lint: {n_cs} changesets, {len(errors)} error(s), "
              f"{sum(1 for x in findings if x.severity == 'WARN')} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
