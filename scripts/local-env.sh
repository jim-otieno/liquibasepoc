#!/usr/bin/env bash
# Print the environment for working against the LOCAL Docker Compose stack.
#
#   eval "$(scripts/local-env.sh)"
#
# Two different addresses for the same database:
#   - Python scripts run on your machine  -> localhost:5432
#   - Liquibase runs in a container       -> postgres:5432 on the compose network
cat <<'EOF'
export DB_KIND=postgresql
export DB_HOST=localhost
export DB_PORT=5432
export DB_NAME=poc
export DB_USER=poc
export DB_PASSWORD=poc
export DB_SSLMODE=prefer
export LB_NETWORK=liquibase-poc_default
export LB_URL=jdbc:postgresql://postgres:5432/poc
export LB_USER=poc
export LB_PASSWORD=poc
unset APP_DB_URL APP_DB_USER APP_DB_PASSWORD
EOF
