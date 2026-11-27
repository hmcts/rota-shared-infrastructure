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

  for required_command in az kubectl kubelogin python3 psql pg_restore vacuumdb; do
    if ! command -v "$required_command" >/dev/null; then
      fail "Required command is missing: ${required_command}"
    fi
  done

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

  portal_owner_user=$(read_secret portal-owner-username)
  portal_owner_password=$(read_secret portal-owner-password)
  portal_application_user=$(read_secret portal-user-username)
  portal_application_password=$(read_secret portal-user-password)
  optimiser_owner_user=$(read_secret optimiser-owner-username)
  optimiser_owner_password=$(read_secret optimiser-owner-password)
  optimiser_application_user=$(read_secret optimiser-user-username)
  optimiser_application_password=$(read_secret optimiser-user-password)
}

load_credentials() {
  load_database_credentials
  export PGSSLMODE=require PGCONNECT_TIMEOUT=10 PGPORT=5432
  # Match the non-production group access configured in postgres.tf.
  export ENABLE_DB_READER_ACCESS=true ENABLE_DB_WRITER_ACCESS=true
  export DB_ACCESS_READER_ROLE='DTS CFT DB Access Reader'
  export DB_ACCESS_WRITER_ROLE='DTS CFT DB Access Writer'
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

prepare_dump() {
  download_dump
  pg_restore --list --schema=public --strict-names "$work_dir/dump.backup" > /dev/null
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
# Target database settings for the shared restore and setup scripts
# -----------------------------------------------------------------------------
use_portal_database() {
  export PGHOST="$portal_database_host" DB_NAME=portaldb
  export DB_ADMIN_USER="$portal_admin_user" DB_ADMIN_PASSWORD="$portal_admin_password"
  export DB_OWNER_USER="$portal_owner_user" DB_OWNER_PASSWORD="$portal_owner_password"
  export DB_APPLICATION_USER="$portal_application_user" DB_APPLICATION_PASSWORD="$portal_application_password"
  export DB_RESTORE_MODE=restore DB_BACKUP="$work_dir/dump.backup"
}

use_optimiser_database() {
  export PGHOST="$optimiser_database_host" DB_NAME=optimiserdb
  export DB_ADMIN_USER="$optimiser_admin_user" DB_ADMIN_PASSWORD="$optimiser_admin_password"
  export DB_OWNER_USER="$optimiser_owner_user" DB_OWNER_PASSWORD="$optimiser_owner_password"
  export DB_APPLICATION_USER="$optimiser_application_user" DB_APPLICATION_PASSWORD="$optimiser_application_password"
  export DB_RESTORE_MODE=reset
  unset DB_BACKUP
}

# -----------------------------------------------------------------------------
# Workload shutdown and database restoration
# -----------------------------------------------------------------------------
stop_workloads() {
  python3 "$scripts_dir/restore-workloads.py" stop "$state_dir/workloads.json" \
    --run-id "$RUN_ID" \
    --contexts "cft-${TARGET_ENVIRONMENT}-00-aks" "cft-${TARGET_ENVIRONMENT}-01-aks"
}

restore_database() {
  bash "$scripts_dir/database-restore/restore-database.sh"
  bash "$scripts_dir/database-setup/setup-database.sh"
}

restore_databases() {
  touch "$state_dir/database-started"

  use_portal_database
  restore_database
  use_optimiser_database
  restore_database

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
  rm -f -- "$work_dir/dump.backup"

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
  connect_clusters
  stop_workloads
  restore_databases
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
