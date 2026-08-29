#!/usr/bin/env bash

set -euo pipefail

# Common postgresql server environment variables
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export DB_ADMIN_USER="${DB_ADMIN_USER:-postgres}"
export DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-${DB_ADMIN_USER}}"
export PGPASSWORD="${DB_ADMIN_PASSWORD}"

# Portal database environment variables
export PORTAL_DB_NAME="${PORTAL_DB_NAME:-mojdb}"

# Drop portal database if it exists
psql --no-psqlrc --set=ON_ERROR_STOP=on --username="${DB_ADMIN_USER}" --dbname=postgres <<SQL
DROP DATABASE IF EXISTS "${PORTAL_DB_NAME}" WITH (FORCE);
SQL

# Optimiser database environment variables
export OPTIMISER_DB_NAME="${OPTIMISER_DB_NAME:-optimiserdb}"

# Drop optimiser database if it exists
psql --no-psqlrc --set=ON_ERROR_STOP=on --username="${DB_ADMIN_USER}" --dbname=postgres <<SQL
DROP DATABASE IF EXISTS "${OPTIMISER_DB_NAME}" WITH (FORCE);
SQL
