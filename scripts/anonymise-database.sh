#!/usr/bin/env bash
# Disable inherited shell tracing before any credentials or data are handled.
set +x
set -euo pipefail
umask 077

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
production_subscription=8999dec3-0104-4a27-94ee-6588559729d1 # DCD-CNP-Prod
artifactory_url=https://artifactory.platform.hmcts.net/artifactory
source_server=rota-psql-dapdb-prod
resource_group=rota-shared-infra-prod
key_vault=rota-shared-prod
storage_account=rotasaprod
container=anonymised-db-dumps
checks_report=${ANONYMISATION_CHECKS_FILE:-/tmp/rota_anonymised_database_checks.csv}
encryption_options=(
  -aes-256-ctr
  -pbkdf2
  -iter 600000
  -md sha512
  -salt
  -pass env:ENCPASSWORD
)

initialise_run_paths() {
  if [[ ! ${RUN_ID:-} =~ ^[0-9]+-[0-9]+$ ]]; then
    fail 'RUN_ID must be Build.BuildId-System.JobAttempt.'
  fi
  : "${AGENT_TEMPDIRECTORY:?AGENT_TEMPDIRECTORY is required}"

  work_dir="${AGENT_TEMPDIRECTORY}/rota-anonymise-${RUN_ID}"
  package_dir="$work_dir/work/package"
  restore_marker="$work_dir/restore-requested"
  temporary_server="rota-dapdb-anon-${RUN_ID}"
}

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------
fail() {
  echo "$*" >&2
  exit 1
}

validate_inputs() {
  : "${PITR_TIMESTAMP:?PITR_TIMESTAMP is required}"
  : "${ANONYMISATION_VERSION:?ANONYMISATION_VERSION is required}"
  if [[ $ANONYMISATION_VERSION == *SNAPSHOT* ]]; then
    fail 'Snapshot package versions are not supported.'
  fi
  : "${POSTGRESQL_HOME:?POSTGRESQL_HOME is required}"
  if [[ -z ${ANONYMISATION_PASSWORD_SECRET:-} ]]; then
    fail 'Set anonymisationPasswordSecret in the pipeline configuration for moj_user.'
  fi
}

# -----------------------------------------------------------------------------
# PostgreSQL client environment
# -----------------------------------------------------------------------------
configure_postgresql() {
  postgres_bin="${POSTGRESQL_HOME}/bin"
  export POSTGRESQL_HOME
  export PATH="${postgres_bin}:${PATH}"
  export LD_LIBRARY_PATH="${POSTGRESQL_HOME}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
}

# -----------------------------------------------------------------------------
# Workspace setup and cleanup
# -----------------------------------------------------------------------------
remove_temporary_database() {
  local existing_server

  if [[ ! -f $restore_marker ]]; then
    return 0
  fi
  if ! az account set --subscription "$production_subscription"; then
    return 1
  fi
  if ! existing_server=$(az postgres flexible-server list \
    --resource-group "$resource_group" \
    --query "[?name=='${temporary_server}'].name | [0]" \
    --output tsv); then
    return 1
  fi

  if [[ -n $existing_server ]]; then
    echo "Deleting temporary server ${temporary_server}."
    if ! az postgres flexible-server delete \
      --resource-group "$resource_group" \
      --name "$temporary_server" \
      --yes \
      --output none; then
      return 1
    fi
  fi

  # Retain the marker on failure so the pipeline's cleanup step can retry.
  rm -f -- "$restore_marker"
}

lock_checks_report() {
  exec 9>>"${checks_report}.lock" || return 1
  flock -n 9
}

cleanup() {
  local status=0

  # Remove local data before waiting for Azure server deletion.
  if [[ ${checks_lock_held:-false} == true ]] || lock_checks_report; then
    rm -f -- "$checks_report" || status=1
  else
    echo "Checks report is still in use; inspect ${checks_report} manually." >&2
    status=1
  fi
  rm -rf -- "$work_dir/work" || status=1
  if remove_temporary_database; then
    rm -rf -- "$work_dir" || status=1
  else
    status=1
  fi
  if (( status != 0 )); then
    echo "Cleanup failed. Check ${work_dir}, ${checks_report} and temporary server ${resource_group}/${temporary_server} manually." >&2
  fi
  return "$status"
}

on_exit() {
  local status=$?
  trap - EXIT

  if ! cleanup; then
    status=1
  fi
  exit "$status"
}

prepare_workspace() {
  # The legacy package writes a fixed CSV path. Keep it exclusive while running.
  if ! lock_checks_report; then
    fail 'Another anonymisation is using the same checks report path.'
  fi
  if [[ -e $work_dir ]]; then
    fail "Run directory already exists: ${work_dir}. Use a new job attempt."
  fi
  mkdir -p "$package_dir"

  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  checks_lock_held=true
  rm -f -- "$checks_report"
}

# -----------------------------------------------------------------------------
# Database credentials
# -----------------------------------------------------------------------------
read_secret() {
  az keyvault secret show \
    --vault-name "$key_vault" \
    --name "$1" \
    --query value \
    --output tsv
}

load_credentials() {
  export PGSSLMODE=require PGCONNECT_TIMEOUT=10 PGPORT=5432 PGDATABASE=mojdb
  az account set --subscription "$production_subscription"

  admin_user=$(read_secret dapdb-postgresql-admin-username)
  admin_password=$(read_secret dapdb-postgresql-admin-password)
  anonymisation_password=$(read_secret "$ANONYMISATION_PASSWORD_SECRET")
  if [[ -z $admin_user || -z $admin_password || -z $anonymisation_password ]]; then
    fail 'Database credentials must not be empty.'
  fi

  encryption_password=$(read_secret anonymised-db-dump-encryption-password)
  if [[ -z $encryption_password ]]; then
    fail 'The backup encryption password must not be empty.'
  fi
}

# -----------------------------------------------------------------------------
# Anonymisation package download
# -----------------------------------------------------------------------------
download_package() {
  local package_name="rotadb-migration-${ANONYMISATION_VERSION}-anonymisation.tar.gz"
  local artifact_path=com/moj/magsrota/portal/build/rotadb-migration
  local repository=${ARTIFACTORY_REPOSITORY:-}
  if [[ -z $repository ]]; then
    fail 'Set the Artifactory repository name in the pipeline YAML after publishing the package.'
  fi
  local package_url="${artifactory_url}/${repository}/${artifact_path}/${ANONYMISATION_VERSION}/${package_name}"
  local curl_args=(--fail --location --silent --show-error)

  # Azure DevOps leaves an undefined optional secret variable as its literal macro.
  if [[ -n ${ARTIFACTORY_TOKEN:-} && $ARTIFACTORY_TOKEN != '$('* ]]; then
    curl_args+=(--header "Authorization: Bearer ${ARTIFACTORY_TOKEN}")
  fi
  curl "${curl_args[@]}" "$package_url" --output "$work_dir/work/$package_name"
  tar -xzf "$work_dir/work/$package_name" -C "$package_dir"

  anonymiser="$package_dir/rota_anonymisation"
  if [[ ! -x $anonymiser ]]; then
    fail 'Package must contain executable rota_anonymisation at its root.'
  fi
}

# -----------------------------------------------------------------------------
# Temporary database restore
# -----------------------------------------------------------------------------
check_source_server() {
  local existing_server
  source_server_id=$(az postgres flexible-server show \
    --resource-group "$resource_group" \
    --name "$source_server" \
    --query id \
    --output tsv)
  if [[ -z $source_server_id ]]; then
    fail 'Could not resolve the production source server.'
  fi

  existing_server=$(az postgres flexible-server list \
    --resource-group "$resource_group" \
    --query "[?name=='${temporary_server}'].name | [0]" \
    --output tsv)
  if [[ -n $existing_server ]]; then
    fail "Temporary server ${temporary_server} already exists; refusing to reuse or delete it."
  fi
}

restore_database() {
  # Mark before submitting so cleanup also handles a partially completed restore.
  touch "$restore_marker"
  echo "Restoring ${source_server} at ${PITR_TIMESTAMP} as ${temporary_server}."
  az postgres flexible-server restore \
    --resource-group "$resource_group" \
    --name "$temporary_server" \
    --source-server "$source_server_id" \
    --restore-time "$PITR_TIMESTAMP" \
    --yes \
    --output none

  temporary_host=$(az postgres flexible-server show \
    --resource-group "$resource_group" \
    --name "$temporary_server" \
    --query fullyQualifiedDomainName \
    --output tsv)
  if [[ $temporary_host != "${temporary_server}.postgres.database.azure.com" ]]; then
    fail 'Unexpected temporary server hostname.'
  fi
}

wait_for_database() {
  local attempt
  for attempt in {1..60}; do
    if PGPASSWORD="$admin_password" "$postgres_bin/psql" \
      -X \
      -w \
      --host="$temporary_host" \
      --username="$admin_user" \
      --dbname=mojdb \
      --set=ON_ERROR_STOP=1 \
      --command='SELECT 1' >/dev/null 2>/dev/null; then
      return 0
    fi
    sleep 10
  done
  fail 'Temporary mojdb did not become accessible within the connection retry window.'
}

# -----------------------------------------------------------------------------
# Database anonymisation
# -----------------------------------------------------------------------------
run_anonymisation() {
  # The legacy package omits ON_ERROR_STOP. Its psql calls read this startup
  # file so SQL-file errors stop the package instead of allowing a partial run.
  printf '\\set ON_ERROR_STOP on\n' > "$work_dir/work/psqlrc"

  echo "Running anonymisation package ${ANONYMISATION_VERSION} against ${temporary_server}."
  # Raw output can contain production data. Discard it instead of retaining logs.
  if ! (
    cd "$package_dir" || exit 1
    export PGHOST="$temporary_host" PGUSER=moj_user PGPASSWORD="$anonymisation_password"
    export PSQLRC="$work_dir/work/psqlrc"
    "$anonymiser" "$temporary_host"
  ) >/dev/null 2>&1; then
    fail 'Anonymisation failed; no dump will be uploaded.'
  fi
}

# -----------------------------------------------------------------------------
# Anonymisation results validation
# -----------------------------------------------------------------------------
validate_anonymisation_report() {
  # The legacy report contains three plain fields: table, column and failure count.
  if ! awk -F, '
    NR == 1 {
      if ($0 != "Table Name,Column Name,Anonymisation Failures") exit 1
      next
    }
    NF != 3 || $1 == "" || $2 == "" || $3 != "0" { exit 1 }
    END { if (NR < 2) exit 1 }
  ' "$checks_report" 2>/dev/null; then
    fail 'Anonymisation checks failed or the CSV is invalid; no dump will be created or uploaded.'
  fi
  if ! rm -f -- "$checks_report"; then
    fail 'Could not remove the plaintext checks report; no dump will be uploaded.'
  fi
}

# -----------------------------------------------------------------------------
# Dump creation and encryption
# -----------------------------------------------------------------------------
create_encrypted_dump() {
  blob_name="mojdb_anonymised_$(date -u +%Y-%m-%d_%H-%M-%S)_${RUN_ID}.backup.enc"
  encrypted_dump_file="$work_dir/work/$blob_name"

  # pipefail stops the run if either pg_dump or OpenSSL fails. Plaintext goes
  # directly through the pipe and is never written to a backup file.
  if ! PGPASSWORD="$admin_password" "$postgres_bin/pg_dump" \
    -w \
    --host="$temporary_host" \
    --username="$admin_user" \
    --dbname=mojdb \
    --schema=public \
    -Fc 2>/dev/null |
    ENCPASSWORD="$encryption_password" openssl enc \
      "${encryption_options[@]}" \
      -out "$encrypted_dump_file" 2>/dev/null; then
    fail 'Database dump or encryption failed; no dump will be uploaded.'
  fi
}

# -----------------------------------------------------------------------------
# Blob upload
# -----------------------------------------------------------------------------
upload_dump() {
  az storage blob upload \
    --account-name "$storage_account" \
    --container-name "$container" \
    --name "$blob_name" \
    --file "$encrypted_dump_file" \
    --type block \
    --auth-mode login \
    --overwrite false \
    --if-none-match '*' \
    --validate-content \
    --output none

  echo "Uploaded https://${storage_account}.blob.core.windows.net/${container}/${blob_name}"
  echo "##vso[task.setvariable variable=anonymisedDumpBlobName]${blob_name}"
}

# -----------------------------------------------------------------------------
# Main execution flow
# -----------------------------------------------------------------------------
main() {
  initialise_run_paths

  case ${1:-run} in
    cleanup)
      cleanup
      return
      ;;
    run)
      ;;
    *)
      fail 'Usage: anonymise-database.sh [run|cleanup]'
      ;;
  esac

  validate_inputs
  configure_postgresql
  prepare_workspace
  load_credentials
  check_source_server
  download_package
  restore_database
  wait_for_database
  run_anonymisation
  validate_anonymisation_report
  create_encrypted_dump

  upload_dump
}

main "$@"
