#!/usr/bin/env bash
set -euo pipefail

# The shared PostgreSQL module provisions the server and grants DB_USER admin
# access. Its non-production writer group is intentionally disabled for Rota.
export AZURE_CONFIG_DIR
AZURE_CONFIG_DIR="$(mktemp -d)"
trap 'rm -rf -- "${AZURE_CONFIG_DIR}"' EXIT
export PGPORT=5432
export PGSSLMODE=require
export PGUSER="${DB_USER}"

az login --identity --output none
export PGPASSWORD
PGPASSWORD="$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)"

PGDATABASE=postgres psql -X -v ON_ERROR_STOP=1 -v writer_group="${DB_WRITER_GROUP}" <<'SQL'
SELECT pgaadauth_create_principal(:'writer_group', false, false)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = :'writer_group'
);
SQL

PGDATABASE="${DB_NAME}" psql -X -v ON_ERROR_STOP=1 -v writer_group="${DB_WRITER_GROUP}" <<'SQL'
GRANT USAGE ON SCHEMA public TO :"writer_group";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"writer_group";
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO :"writer_group";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"writer_group";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO :"writer_group";
SQL
