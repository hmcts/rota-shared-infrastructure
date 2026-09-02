#!/usr/bin/env bash

set -euo pipefail

SCRIPTS_DIR=$(cd "$(dirname "$0")/.." && pwd)

# Common postgresql server environment variables
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export DB_ADMIN_USER="${DB_ADMIN_USER:-postgres}"
export DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-${DB_ADMIN_USER}}"
export PGPASSWORD="${DB_ADMIN_PASSWORD}"

# Non-production reader and writer database roles
export DB_ACCESS_READER_ROLE="${DB_ACCESS_READER_ROLE:-DTS CFT DB Access Reader}"
export DB_ACCESS_WRITER_ROLE="${DB_ACCESS_WRITER_ROLE:-DTS CFT DB Access Writer}"
export ENABLE_DB_READER_ACCESS="${ENABLE_DB_READER_ACCESS:-true}"
export ENABLE_DB_WRITER_ACCESS="${ENABLE_DB_WRITER_ACCESS:-false}"

# Create non-production reader role
DB_NOLOGIN_ROLE="${DB_ACCESS_READER_ROLE}" /usr/bin/env bash "${SCRIPTS_DIR}/database-init/create-nologin-role.sh"

# Create non-production writer role
DB_NOLOGIN_ROLE="${DB_ACCESS_WRITER_ROLE}" /usr/bin/env bash "${SCRIPTS_DIR}/database-init/create-nologin-role.sh"

# Portal database environment variables
export DB_NAME="${PORTAL_DB_NAME:-mojdb}"
export DB_OWNER_USER="${PORTAL_DB_OWNER_USER:-moj_owner}"
export DB_OWNER_PASSWORD="${PORTAL_DB_OWNER_PASSWORD:-${DB_OWNER_USER}}"
export DB_APPLICATION_USER="${PORTAL_DB_APPLICATION_USER:-moj_user}"
export DB_APPLICATION_PASSWORD="${PORTAL_DB_APPLICATION_PASSWORD:-${DB_APPLICATION_USER}}"

# Create portal database
/usr/bin/env bash "${SCRIPTS_DIR}/database-init/create-database.sh"

# Setup portal database
/usr/bin/env bash "${SCRIPTS_DIR}/database-setup/setup-postgres.sh"

# Optimiser database environment variables
export DB_NAME="${OPTIMISER_DB_NAME:-optimiserdb}"
export DB_OWNER_USER="${OPTIMISER_DB_OWNER_USER:-optimiser_owner}"
export DB_OWNER_PASSWORD="${OPTIMISER_DB_OWNER_PASSWORD:-${DB_OWNER_USER}}"
export DB_APPLICATION_USER="${OPTIMISER_DB_APPLICATION_USER:-optimiser_user}"
export DB_APPLICATION_PASSWORD="${OPTIMISER_DB_APPLICATION_PASSWORD:-${DB_APPLICATION_USER}}"

# Create optimiser database
/usr/bin/env bash "${SCRIPTS_DIR}/database-init/create-database.sh"

# Setup optimiser database
/usr/bin/env bash "${SCRIPTS_DIR}/database-setup/setup-postgres.sh"
