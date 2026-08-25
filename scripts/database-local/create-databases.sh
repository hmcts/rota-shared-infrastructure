#!/usr/bin/env bash

set -euo pipefail

# Common postgresql server environment variables
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export DB_ADMIN_USER="${DB_ADMIN_USER:-postgres}"
export DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-${DB_ADMIN_USER}}"
export PGPASSWORD="${DB_ADMIN_PASSWORD}"

# Optimiser database environment variables
export DB_NAME="${OPTIMISER_DB_NAME:-optimiserdb}"
export DB_OWNER_USER="${OPTIMISER_DB_OWNER_USER:-optimiser_owner}"
export DB_OWNER_PASSWORD="${OPTIMISER_DB_OWNER_PASSWORD:-${DB_OWNER_USER}}"
export DB_APPLICATION_USER="${OPTIMISER_DB_APPLICATION_USER:-optimiser_user}"
export DB_APPLICATION_PASSWORD="${OPTIMISER_DB_APPLICATION_PASSWORD:-${DB_APPLICATION_USER}}"

# Create optimiser database if it does not already exist
psql --no-psqlrc --set=ON_ERROR_STOP=on --username="${DB_ADMIN_USER}" --dbname=postgres <<SQL
SELECT format(
  'CREATE DATABASE %I WITH TEMPLATE template0 ENCODING ''UTF8'' LC_COLLATE ''en_GB.UTF-8'' LC_CTYPE ''en_GB.UTF-8''',
  '${DB_NAME}'
)
WHERE NOT EXISTS (
  SELECT FROM pg_catalog.pg_database WHERE datname = '${DB_NAME}'
)
\gexec
SQL

# Setup optimiser database
SETUP_SCRIPT_DIR=$(cd "$(dirname "$0")/.." && pwd)
/usr/bin/env bash "${SETUP_SCRIPT_DIR}/database-setup/setup-postgres.sh"
