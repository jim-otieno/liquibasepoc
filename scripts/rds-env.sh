#!/usr/bin/env bash
# Print the environment for working against the RDS instance from this machine.
# Reads Terraform outputs and the master password from Secrets Manager.
#
#   eval "$(scripts/rds-env.sh)"          # all scripts now target RDS
#   eval "$(scripts/rds-env.sh mydb)"     # a specific database on the instance
#
# The password is only exported into your shell; it is never written to disk.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DBNAME="${1:-poc}"
tf() { terraform -chdir="$ROOT/infra/aws" output -raw "$1"; }

HOST="$(tf endpoint)"
USER_NAME="$(tf master_username)"
PASS="$(aws secretsmanager get-secret-value --secret-id "$(tf master_secret_arn)" \
        --query SecretString --output text | python -c 'import sys,json;print(json.load(sys.stdin)["password"])')"

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
export LB_NETWORK=host
export APP_DB_URL=$(q "jdbc:postgresql://$HOST:5432/$DBNAME?sslmode=require")
export APP_DB_USER=$(q "$USER_NAME")
export APP_DB_PASSWORD=$(q "$PASS")
EOF
