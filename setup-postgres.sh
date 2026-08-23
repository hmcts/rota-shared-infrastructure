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
REVOKE CREATE ON SCHEMA public FROM "${DB_APPLICATION_USER}";

-- Grant owner role to admin user
GRANT "${DB_OWNER_USER}" TO "${DB_ADMIN_USER}";

-- Switch to owner role for grants to application user
SET ROLE "${DB_OWNER_USER}";

-- Grant limited rights to existing tables and sequences in public schema to application user
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "${DB_APPLICATION_USER}";
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO "${DB_APPLICATION_USER}";

-- Grant application rights on future owner-created objects in public schema
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "${DB_APPLICATION_USER}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO "${DB_APPLICATION_USER}";

-- Reset role back to admin role
RESET ROLE;
SQL

if [[ "${ENABLE_CFT_READER_ACCESS}" == "true" ]]; then
  psql --no-psqlrc --set=ON_ERROR_STOP=on --username="${DB_ADMIN_USER}" --dbname="${DB_NAME}" <<SQL
-- Grant CFT reader access to public schema
GRANT USAGE ON SCHEMA public TO "${CFT_DB_ACCESS_READER_ROLE}";

-- Switch to owner role for grants
SET ROLE "${DB_OWNER_USER}";

-- Grant CFT reader access to existing tables and future owner-created tables in public schema
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "${CFT_DB_ACCESS_READER_ROLE}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO "${CFT_DB_ACCESS_READER_ROLE}";

-- Reset role back to admin role
RESET ROLE;
SQL
fi
