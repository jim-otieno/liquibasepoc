"""Tests for the phase linter: the real changelog passes, unsafe patterns fail."""
from pathlib import Path
import textwrap

import phase_lint

REPO = Path(__file__).resolve().parents[2]
MASTER = REPO / "db" / "changelog" / "db.changelog-master.yaml"


def write(tmp_path: Path, body: str) -> Path:
    p = tmp_path / "master.yaml"
    p.write_text(textwrap.dedent(body), encoding="utf-8")
    return p


def rules(findings, severity="ERROR"):
    return {f.rule for f in findings if f.severity == severity}


def test_repository_changelog_is_clean():
    findings = phase_lint.lint(MASTER)
    assert rules(findings) == set(), "\n".join(map(str, findings))


def test_missing_label(tmp_path):
    m = write(tmp_path, """
        databaseChangeLog:
          - changeSet:
              id: a
              author: t
              changes:
                - tagDatabase: {tag: x}
    """)
    assert "phase-label" in rules(phase_lint.lint(m))


def test_drop_column_outside_contract(tmp_path):
    m = write(tmp_path, """
        databaseChangeLog:
          - changeSet:
              id: a
              author: t
              labels: expand
              changes:
                - sql: {sql: "SET lock_timeout = '2s'"}
                - sql: {sql: "ALTER SESSION SET ddl_lock_timeout = 2"}
                - dropColumn: {tableName: t, columnName: c}
              rollback:
                - sql: {sql: "SELECT 1"}
    """)
    assert "destructive-outside-contract" in rules(phase_lint.lint(m))


def test_rename_column_is_breaking(tmp_path):
    m = write(tmp_path, """
        databaseChangeLog:
          - changeSet:
              id: a
              author: t
              labels: expand
              changes:
                - renameColumn: {tableName: t, oldColumnName: a, newColumnName: b}
              rollback:
                - sql: {sql: "SELECT 1"}
    """)
    assert "breaking-change" in rules(phase_lint.lint(m))


def test_index_without_concurrently(tmp_path):
    m = write(tmp_path, """
        databaseChangeLog:
          - changeSet:
              id: a
              author: t
              labels: expand
              changes:
                - sql: {dbms: postgresql, sql: "SET lock_timeout = '2s'"}
                - sql: {dbms: postgresql, sql: "CREATE INDEX ix ON t (c)"}
              rollback:
                - sql: {sql: "DROP INDEX ix"}
    """)
    assert "locking-ddl" in rules(phase_lint.lint(m))


def test_concurrently_requires_no_transaction(tmp_path):
    m = write(tmp_path, """
        databaseChangeLog:
          - changeSet:
              id: a
              author: t
              labels: expand
              changes:
                - sql: {dbms: postgresql, sql: "SET lock_timeout = '2s'"}
                - sql: {dbms: postgresql, sql: "CREATE INDEX CONCURRENTLY ix ON t (c)"}
              rollback:
                - sql: {sql: "DROP INDEX ix"}
    """)
    assert "concurrently-in-txn" in rules(phase_lint.lint(m))


def test_constraint_must_be_not_valid(tmp_path):
    m = write(tmp_path, """
        databaseChangeLog:
          - changeSet:
              id: a
              author: t
              labels: harden
              changes:
                - sql: {dbms: postgresql, sql: "SET lock_timeout = '2s'"}
                - sql: {dbms: postgresql, sql: "ALTER TABLE t ADD CONSTRAINT c CHECK (x IS NOT NULL)"}
              rollback:
                - sql: {sql: "ALTER TABLE t DROP CONSTRAINT c"}
    """)
    assert "locking-ddl" in rules(phase_lint.lint(m))


def test_ddl_without_lock_timeout(tmp_path):
    m = write(tmp_path, """
        databaseChangeLog:
          - changeSet:
              id: a
              author: t
              labels: expand
              preConditions:
                - onFail: MARK_RAN
              changes:
                - addColumn:
                    tableName: t
                    columns:
                      - column: {name: c, type: INT}
              rollback:
                - dropColumn: {tableName: t, columnName: c}
    """)
    assert "lock-timeout" in rules(phase_lint.lint(m))


def test_missing_rollback(tmp_path):
    m = write(tmp_path, """
        databaseChangeLog:
          - changeSet:
              id: a
              author: t
              labels: migrate-inline
              changes:
                - sql: {sql: "UPDATE t SET b = a WHERE b IS NULL"}
    """)
    assert "rollback" in rules(phase_lint.lint(m))
