#!/usr/bin/env bash

set -euo pipefail

export PGPORT="${PGPORT:-5432}"
export PGPASSWORD="${DB_ADMIN_PASSWORD}"

psql --no-psqlrc --set=ON_ERROR_STOP=on --username="${DB_ADMIN_USER}" --dbname="${DB_NAME}" <<SQL
-- Ensure the pg_stat_statements extension exists
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Create owner user if it does not exist
SELECT format('CREATE ROLE %I LOGIN', '${DB_OWNER_USER}')
WHERE NOT EXISTS (
  SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_OWNER_USER}'
)
\gexec

-- Create application user if it does not exist
SELECT format('CREATE ROLE %I LOGIN', '${DB_APPLICATION_USER}')
WHERE NOT EXISTS (
  SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_APPLICATION_USER}'
)
\gexec

-- Set user passwords
ALTER ROLE "${DB_OWNER_USER}" WITH LOGIN PASSWORD '${DB_OWNER_PASSWORD}';
ALTER ROLE "${DB_APPLICATION_USER}" WITH LOGIN PASSWORD '${DB_APPLICATION_PASSWORD}';

-- Configure database and public schema access
GRANT CONNECT ON DATABASE "${DB_NAME}" TO "${DB_OWNER_USER}";
GRANT CONNECT ON DATABASE "${DB_NAME}" TO "${DB_APPLICATION_USER}";
GRANT USAGE, CREATE ON SCHEMA public TO "${DB_OWNER_USER}";
GRANT USAGE ON SCHEMA public TO "${DB_APPLICATION_USER}";

-- Grant owner role to admin user
GRANT "${DB_OWNER_USER}" TO "${DB_ADMIN_USER}";

-- Switch to owner role for grants to application user
SET ROLE "${DB_OWNER_USER}";

-- Grant application user access to existing and future owner-created tables and sequences in public schema
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "${DB_APPLICATION_USER}";
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO "${DB_APPLICATION_USER}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "${DB_APPLICATION_USER}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO "${DB_APPLICATION_USER}";

-- Reset role back to admin role
RESET ROLE;
SQL

if [[ "${ENABLE_DB_READER_ACCESS:-false}" == "true" && -n "${DB_ACCESS_READER_ROLE:-}" ]]; then
  psql --no-psqlrc --set=ON_ERROR_STOP=on --username="${DB_ADMIN_USER}" --dbname="${DB_NAME}" <<SQL
-- Grant database reader role access to public schema
GRANT CONNECT ON DATABASE "${DB_NAME}" TO "${DB_ACCESS_READER_ROLE}";
GRANT USAGE ON SCHEMA public TO "${DB_ACCESS_READER_ROLE}";

-- Switch to owner role for grants to reader role
SET ROLE "${DB_OWNER_USER}";

-- Grant reader role access to existing and future owner-created tables in public schema
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "${DB_ACCESS_READER_ROLE}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO "${DB_ACCESS_READER_ROLE}";

-- Reset role back to admin role
RESET ROLE;
SQL
fi

if [[ "${ENABLE_DB_WRITER_ACCESS:-false}" == "true" && -n "${DB_ACCESS_WRITER_ROLE:-}" ]]; then
  psql --no-psqlrc --set=ON_ERROR_STOP=on --username="${DB_ADMIN_USER}" --dbname="${DB_NAME}" <<SQL
-- Grant database writer role access to public schema
GRANT CONNECT ON DATABASE "${DB_NAME}" TO "${DB_ACCESS_WRITER_ROLE}";
GRANT USAGE ON SCHEMA public TO "${DB_ACCESS_WRITER_ROLE}";

-- Switch to owner role for grants to writer role
SET ROLE "${DB_OWNER_USER}";

-- Grant writer role access to existing and future owner-created tables and sequences in public schema
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "${DB_ACCESS_WRITER_ROLE}";
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO "${DB_ACCESS_WRITER_ROLE}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "${DB_ACCESS_WRITER_ROLE}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO "${DB_ACCESS_WRITER_ROLE}";

-- Reset role back to admin role
RESET ROLE;
SQL
fi
