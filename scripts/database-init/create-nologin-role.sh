#!/usr/bin/env bash

set -euo pipefail

# Create nologin role if it does not already exist
psql --no-psqlrc --set=ON_ERROR_STOP=on --username="${DB_ADMIN_USER}" --dbname=postgres <<SQL
SELECT format('CREATE ROLE %I NOLOGIN', '${DB_NOLOGIN_ROLE}')
WHERE NOT EXISTS (
  SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_NOLOGIN_ROLE}'
)
\gexec
SQL
