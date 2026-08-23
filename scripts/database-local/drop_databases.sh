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

# Drop optimiser database if it exists
psql --no-psqlrc --set=ON_ERROR_STOP=on --username="${DB_ADMIN_USER}" --dbname=postgres <<SQL
DROP DATABASE IF EXISTS "${DB_NAME}" WITH (FORCE);
SQL
