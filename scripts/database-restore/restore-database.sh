#!/usr/bin/env bash

set -euo pipefail

export PGHOST="${PGHOST}"
export PGPORT="${PGPORT:-5432}"
export PGPASSWORD="${DB_ADMIN_PASSWORD}"

# Check the database backup is valid and contains the public schema
pg_restore --list --schema=public --strict-names "${DB_BACKUP}" > /dev/null

# Drop and recreate public schema in database
psql --no-psqlrc --set=ON_ERROR_STOP=on --username="${DB_ADMIN_USER}" --dbname="${DB_NAME}" <<SQL
-- Check the owner role exists and admin can assume it
SET ROLE "${DB_OWNER_USER}";
RESET ROLE;

-- Disconnect all connections except this one
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = current_database()
  AND pid <> pg_backend_pid();

-- Recreate the public schema
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;

-- Re-add public schema access to owner role
GRANT USAGE, CREATE ON SCHEMA public TO "${DB_OWNER_USER}";
SQL

# Restore public schema from database backup
pg_restore --exit-on-error --no-password --verbose --jobs=4 --username="${DB_ADMIN_USER}" --dbname="${DB_NAME}" --schema=public --role="${DB_OWNER_USER}" --no-owner --no-privileges "${DB_BACKUP}"

# Run postgresql analyze on the database
vacuumdb --analyze-only --jobs=4 --username="${DB_ADMIN_USER}" --dbname="${DB_NAME}" --echo
