#!/usr/bin/env bash
# Print the environment for working against the RDS instance from this machine.
# Reads Terraform outputs (or, with RDS_INSTANCE set, the AWS API) and the
# master password from Secrets Manager.
#
#   eval "$(scripts/rds-env.sh)"          # all scripts now target RDS
#   eval "$(scripts/rds-env.sh mydb)"     # a specific database on the instance
#   export RDS_INSTANCE=liquibase-poc     # no Terraform state here (e.g. Jenkins):
#   eval "$(scripts/rds-env.sh)"          #   look the instance up via the AWS API
#
# The password is only exported into your shell; it is never written to disk.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DBNAME="${1:-poc}"
PY="$(command -v python || command -v python3)"
tf() { terraform -chdir="$ROOT/infra/aws" output -raw "$1"; }

if [ -n "${RDS_INSTANCE:-}" ]; then
  read -r HOST USER_NAME SECRET_ARN < <(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE" \
    --query 'DBInstances[0].[Endpoint.Address,MasterUsername,MasterUserSecret.SecretArn]' --output text | tr -d '\r')
  [ -n "${SECRET_ARN:-}" ] || { echo "rds-env: could not look up RDS instance $RDS_INSTANCE" >&2; exit 1; }
else
  HOST="$(tf endpoint)"
  USER_NAME="$(tf master_username)"
  SECRET_ARN="$(tf master_secret_arn)"
fi
PASS="$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
        --query SecretString --output text | "$PY" -c 'import sys,json;print(json.load(sys.stdin)["password"])')"

q() { printf "%q" "$1"; }
cat <<EOF
export DB_KIND=postgresql
export DB_HOST=$(q "$HOST")
export DB_PORT=5432
export DB_NAME=$(q "$DBNAME")
export DB_USER=$(q "$USER_NAME")
export DB_PASSWORD=$(q "$PASS")
export DB_SSLMODE=require
export LB_URL=$(q "jdbc:postgresql://$HOST:5432/$DBNAME?sslmode=require")
export LB_USER=$(q "$USER_NAME")
export LB_PASSWORD=$(q "$PASS")
# Docker's default bridge network reaches the internet on Windows, macOS and Linux
# (host networking is not available on Docker Desktop by default).
export LB_NETWORK=bridge
export APP_DB_URL=$(q "jdbc:postgresql://$HOST:5432/$DBNAME?sslmode=require")
export APP_DB_USER=$(q "$USER_NAME")
export APP_DB_PASSWORD=$(q "$PASS")
EOF
