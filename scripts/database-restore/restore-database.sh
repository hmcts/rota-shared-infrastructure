#!/usr/bin/env bash

set -euo pipefail

export PGHOST="${PGHOST}"
export PGPORT="${PGPORT:-5432}"
export PGPASSWORD="${DB_ADMIN_PASSWORD}"

# Reset-only mode leaves the optimiser schema empty for Flyway on startup.
case ${DB_RESTORE_MODE:-restore} in
  restore)
    pg_restore --list --schema=public --strict-names "${DB_BACKUP}" > /dev/null
    ;;
  reset)
    ;;
  *)
    echo 'DB_RESTORE_MODE must be restore or reset.' >&2
    exit 1
    ;;
esac

# Drop and recreate public schema in database
psql --no-psqlrc --set=ON_ERROR_STOP=on --username="${DB_ADMIN_USER}" --dbname="${DB_NAME}" <<SQL
-- Create owner user if it does not exist
SELECT format('CREATE ROLE %I LOGIN', '${DB_OWNER_USER}')
WHERE NOT EXISTS (
  SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_OWNER_USER}'
)
\gexec

-- Grant owner role to admin user
GRANT "${DB_OWNER_USER}" TO "${DB_ADMIN_USER}";

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
if [[ ${DB_RESTORE_MODE:-restore} == restore ]]; then
  pg_restore --exit-on-error --no-password --verbose --jobs=4 --username="${DB_ADMIN_USER}" --dbname="${DB_NAME}" --schema=public --role="${DB_OWNER_USER}" --no-owner --no-privileges "${DB_BACKUP}"
fi

# Run postgresql analyze on the database
vacuumdb --analyze-only --jobs=4 --username="${DB_ADMIN_USER}" --dbname="${DB_NAME}" --echo
