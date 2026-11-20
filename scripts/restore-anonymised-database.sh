#!/usr/bin/env bash
# Disable inherited shell tracing before any credentials or data are handled.
set +x
set -euo pipefail
umask 077

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
scripts_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
container=anonymised-db-dumps

initialise_run_paths() {
  if [[ ! ${RUN_ID:-} =~ ^[0-9]+-[0-9]+$ ]]; then
    fail 'RUN_ID must be Build.BuildId-System.JobAttempt.'
  fi
  : "${AGENT_TEMPDIRECTORY:?AGENT_TEMPDIRECTORY is required}"

  work_dir="${AGENT_TEMPDIRECTORY}/rota-restore-${RUN_ID}"
  state_dir="$work_dir/state"
  export KUBECONFIG="$work_dir/kubeconfig"
}

# -----------------------------------------------------------------------------
# Input validation and PostgreSQL client environment
# -----------------------------------------------------------------------------
fail() {
  echo "$*" >&2
  exit 1
}

validate_inputs() {
  local subscription_id required_command

  export PATH="${POSTGRESQL_HOME:-/usr}/bin:$PATH"
  case ${TARGET_ENVIRONMENT:-} in
    dev|sandbox|aat|demo|ithc|perftest)
      ;;
    *)
      fail 'Select a supported non-production target environment.'
      ;;
  esac

  if [[ ! ${BLOB_NAME:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    fail 'BLOB_NAME must be a single filename containing only letters, digits, dots, underscores or hyphens.'
  fi

  for subscription_id in "${TARGET_SUBSCRIPTION:-}" "${AKS_SUBSCRIPTION:-}"; do
    if [[ ! $subscription_id =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
      fail 'Supply explicit target-database and AKS subscription IDs.'
    fi
  done

  for required_command in az kubectl kubelogin python3 psql pg_restore; do
    if ! command -v "$required_command" >/dev/null; then
      fail "Required command is missing: ${required_command}"
    fi
  done

  if [[ $(pg_restore --version) != 'pg_restore (PostgreSQL) 15.'* ]]; then
    fail 'PostgreSQL 15 pg_restore is required. Set POSTGRESQL_HOME to its installation directory.'
  fi
  key_vault="rota-shared-${TARGET_ENVIRONMENT}"
}

# -----------------------------------------------------------------------------
# Database credentials
# -----------------------------------------------------------------------------
read_secret() {
  az keyvault secret show \
    --subscription "$TARGET_SUBSCRIPTION" \
    --vault-name "$key_vault" \
    --name "$1" \
    --query value \
    --output tsv
}

load_database_credentials() {
  portal_database_host=$(read_secret dapdb-postgresql-fqdn)
  portal_admin_user=$(read_secret dapdb-postgresql-admin-username)
  portal_admin_password=$(read_secret dapdb-postgresql-admin-password)
  optimiser_database_host=$(read_secret dopdb-postgresql-fqdn)
  optimiser_admin_user=$(read_secret dopdb-postgresql-admin-username)
  optimiser_admin_password=$(read_secret dopdb-postgresql-admin-password)

  if [[ $portal_database_host != "rota-psql-dapdb-${TARGET_ENVIRONMENT}.postgres.database.azure.com" ]]; then
    fail 'Unexpected DAPDB hostname.'
  fi
  if [[ $optimiser_database_host != "rota-psql-dopdb-${TARGET_ENVIRONMENT}.postgres.database.azure.com" ]]; then
    fail 'Unexpected DOPDB hostname.'
  fi
  if [[ -z $portal_admin_user || -z $portal_admin_password || -z $optimiser_admin_user || -z $optimiser_admin_password ]]; then
    fail 'Empty database credentials.'
  fi
}

load_credentials() {
  load_database_credentials
  export PGSSLMODE=require PGCONNECT_TIMEOUT=10 PGPORT=5432
}

# -----------------------------------------------------------------------------
# Decrypted archive download and validation
# -----------------------------------------------------------------------------
download_dump() {
  local source_account="rotasa${TARGET_ENVIRONMENT}"

  az storage blob download \
    --subscription "$TARGET_SUBSCRIPTION" \
    --account-name "$source_account" \
    --container-name "$container" \
    --name "$BLOB_NAME" \
    --file "$work_dir/dump.backup" \
    --auth-mode login \
    --validate-content \
    --no-progress \
    --output none
}

prepare_restore_list() {
  # Read a regular file: --list can stop after the table of contents without
  # breaking an upstream decryption process or leaving unread pipe data.
  pg_restore --list "$work_dir/dump.backup" > "$work_dir/archive.list"
  python3 - "$work_dir/archive.list" "$work_dir/restore.list" <<'PY'
from pathlib import Path
import re
import sys

archive_list_path = Path(sys.argv[1])
restore_list_path = Path(sys.argv[2])
archive_contents = archive_list_path.read_text()

if not re.search(r'^\d+; \d+ \d+ TABLE public ', archive_contents, re.M):
    raise SystemExit('The archive contains no public tables.')

# The target recreates public and its extensions with its own owners and grants.
excluded_entries = r'^\d+; \d+ \d+ (SCHEMA - public |EXTENSION |COMMENT - EXTENSION )'
restore_entries = []
for entry in archive_contents.splitlines():
    if not re.match(excluded_entries, entry):
        restore_entries.append(entry)

restore_list_path.write_text('\n'.join(restore_entries) + '\n')
PY
}

validate_dump_archive() {
  # Read the whole archive before downtime, not just its table of contents.
  pg_restore \
    --no-owner \
    --no-privileges \
    --schema=public \
    --use-list="$work_dir/restore.list" \
    --file=/dev/null \
    "$work_dir/dump.backup"
}

prepare_dump() {
  download_dump
  prepare_restore_list
  validate_dump_archive
}

# -----------------------------------------------------------------------------
# AKS cluster discovery and authentication
# -----------------------------------------------------------------------------
discover_clusters() {
  az aks list --subscription "$AKS_SUBSCRIPTION" --output json > "$work_dir/clusters.json"
  python3 - "$work_dir/clusters.json" "$TARGET_ENVIRONMENT" > "$work_dir/clusters.tsv" <<'PY'
import json
from pathlib import Path
import sys

cluster_inventory_path = Path(sys.argv[1])
target_environment = sys.argv[2]
clusters = json.loads(cluster_inventory_path.read_text())

for cluster_number in ('00', '01'):
    cluster_name = f'cft-{target_environment}-{cluster_number}-aks'
    matches = [cluster for cluster in clusters if cluster['name'] == cluster_name]
    if len(matches) != 1:
        raise SystemExit(
            f'Expected exactly one AKS cluster named {cluster_name}; refusing a partial shutdown.'
        )
    print(cluster_name, matches[0]['resourceGroup'], sep='\t')
PY
}

connect_clusters() {
  local cluster_name resource_group

  discover_clusters
  while IFS=$'\t' read -r cluster_name resource_group; do
    az aks get-credentials \
      --subscription "$AKS_SUBSCRIPTION" \
      --resource-group "$resource_group" \
      --name "$cluster_name" \
      --context "$cluster_name" \
      --file "$KUBECONFIG" \
      --overwrite-existing \
      --output none
  done < "$work_dir/clusters.tsv"
  kubelogin convert-kubeconfig --login azurecli
}

# -----------------------------------------------------------------------------
# Target database selection and preflight checks
# -----------------------------------------------------------------------------
use_portal_database() {
  export PGHOST="$portal_database_host"
  export PGUSER="$portal_admin_user" PGPASSWORD="$portal_admin_password" PGDATABASE=mojdb
}

use_optimiser_database() {
  export PGHOST="$optimiser_database_host"
  export PGUSER="$optimiser_admin_user" PGPASSWORD="$optimiser_admin_password" PGDATABASE=optimiserdb
}

check_database() {
  local owner_user=$1 application_user=$2

  psql \
    -X \
    -w \
    --set=ON_ERROR_STOP=1 \
    --set="restore_owner=$owner_user" \
    --set="application_user=$application_user" \
    --quiet <<'SQL'
-- Fail before downtime if the database-users branch has not been applied.
SET ROLE :"restore_owner";
RESET ROLE;
SELECT :'application_user'::regrole;

-- This pipeline is written for the PostgreSQL 15 servers in postgres.tf.
DO $$
BEGIN
  IF current_setting('server_version_num')::int / 10000 <> 15 THEN
    RAISE EXCEPTION 'Expected PostgreSQL 15';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_namespace WHERE nspname = 'public') THEN
    RAISE EXCEPTION 'The target public schema is missing';
  END IF;
  IF EXISTS (
    SELECT FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE n.nspname = 'public' AND e.extname NOT IN ('pg_stat_statements', 'pg_buffercache')
  ) THEN
    RAISE EXCEPTION 'Unexpected extension in public; review it before restoring';
  END IF;
END $$;
SQL
}

check_databases() {
  use_portal_database
  check_database portal_owner portal_user
  use_optimiser_database
  check_database optimiser_owner optimiser_user
}

# -----------------------------------------------------------------------------
# Workload shutdown and database restoration
# -----------------------------------------------------------------------------
stop_workloads() {
  python3 "$scripts_dir/restore-workloads.py" stop "$state_dir/workloads.json" \
    --run-id "$RUN_ID" \
    --contexts "cft-${TARGET_ENVIRONMENT}-00-aks" "cft-${TARGET_ENVIRONMENT}-01-aks"
}

write_schema_restore_sql() {
  local restore_blob=$1

  # A failed producer never emits COMMIT. psql then rolls the schema replacement
  # back on EOF; pipefail also propagates pg_restore failures.
  cat "$scripts_dir/database-restore/rebuild-public-schema.sql" || return $?
  if [[ $restore_blob == true ]]; then
    pg_restore \
      --no-owner \
      --no-privileges \
      --schema=public \
      --use-list="$work_dir/restore.list" \
      --file=- \
      "$work_dir/dump.backup" || return $?
  fi
  printf '\nCOMMIT;\nANALYZE;\n'
}

rebuild_schema() {
  local owner_user=$1 application_user=$2 restore_blob=$3

  write_schema_restore_sql "$restore_blob" | psql \
    -X \
    -w \
    --quiet \
    --set=ON_ERROR_STOP=1 \
    --set="restore_owner=$owner_user" \
    --set="application_user=$application_user"
}

restore_databases() {
  touch "$state_dir/database-started"

  use_portal_database
  rebuild_schema portal_owner portal_user true
  use_optimiser_database
  rebuild_schema optimiser_owner optimiser_user false

  touch "$state_dir/database-complete"
}

# -----------------------------------------------------------------------------
# Workspace setup and cleanup
# -----------------------------------------------------------------------------
prepare_workspace() {
  if [[ -e $work_dir ]]; then
    fail 'Restore directory already exists; use a new job attempt.'
  fi
  mkdir -p "$state_dir"
  echo '##vso[task.setvariable variable=restoreStateReady]true'

  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

resume_workloads() {
  # The final always() task logs in again and recreates the isolated kubeconfig.
  if [[ ! -f $KUBECONFIG ]]; then
    connect_clusters || return $?
  fi
  python3 "$scripts_dir/restore-workloads.py" resume "$state_dir/workloads.json"
}

cleanup() {
  if [[ ! -d $work_dir ]]; then
    return 0
  fi
  rm -f -- "$work_dir/dump.backup" "$work_dir/restore.list" "$work_dir/archive.list"

  if [[ -f $state_dir/database-started && ! -f $state_dir/database-complete ]]; then
    echo "Database restore failed. Workloads remain stopped. Recover using ${state_dir}/workloads.json before resuming." >&2
    return 1
  fi
  if [[ -f $state_dir/workloads.json ]]; then
    if ! resume_workloads; then
      return 1
    fi
  fi
  # Keep the non-secret recovery record for the pipeline artifact.
  rm -f -- "$KUBECONFIG"
}

on_exit() {
  local status=$?
  trap - EXIT

  if ! cleanup; then
    status=1
  fi
  exit "$status"
}

# -----------------------------------------------------------------------------
# Main execution flow
# -----------------------------------------------------------------------------
main() {
  initialise_run_paths

  case ${1:-run} in
    cleanup)
      # No credentials or blob are needed to restore workload settings.
      : "${TARGET_ENVIRONMENT:?TARGET_ENVIRONMENT is required}"
      : "${AKS_SUBSCRIPTION:?AKS_SUBSCRIPTION is required}"
      cleanup
      return
      ;;
    run)
      ;;
    *)
      fail 'Usage: restore-anonymised-database.sh [run|cleanup]'
      ;;
  esac

  validate_inputs
  prepare_workspace
  load_credentials
  prepare_dump
  check_databases
  connect_clusters
  stop_workloads
  restore_databases
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
