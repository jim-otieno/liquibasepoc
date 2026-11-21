"""Shared database connection helper for experiment scripts (PostgreSQL or Oracle).

Connection settings come from environment variables so that pipelines can
inject secrets:
    DB_KIND      postgresql (default) | oracle
    DB_HOST      default localhost
    DB_PORT      default 5432 / 1521
    DB_NAME      PostgreSQL database or Oracle service name (default poc / FREEPDB1)
    DB_USER      default poc
    DB_PASSWORD  default poc
"""
from __future__ import annotations

import os


def kind() -> str:
    return os.environ.get("DB_KIND", "postgresql").lower()


def connect(autocommit: bool = False):
    host = os.environ.get("DB_HOST", "localhost")
    user = os.environ.get("DB_USER", "poc")
    password = os.environ.get("DB_PASSWORD", "poc")
    if kind() == "oracle":
        import oracledb  # pip install oracledb (thin mode, no Oracle client needed)

        port = int(os.environ.get("DB_PORT", "1521"))
        service = os.environ.get("DB_NAME", "FREEPDB1")
        conn = oracledb.connect(user=user, password=password, dsn=f"{host}:{port}/{service}")
        conn.autocommit = autocommit
        return conn

    import psycopg  # pip install "psycopg[binary]"

    port = int(os.environ.get("DB_PORT", "5432"))
    dbname = os.environ.get("DB_NAME", "poc")
    return psycopg.connect(host=host, port=port, dbname=dbname, user=user, password=password,
                           autocommit=autocommit)


def param(i: int) -> str:
    """Bind placeholder for the current driver (1-based index)."""
    return f":{i}" if kind() == "oracle" else "%s"
