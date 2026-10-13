#!/usr/bin/env bash

set -euo pipefail

# Create database if it does not already exist
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
