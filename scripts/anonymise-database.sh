#!/usr/bin/env bash
# Disable inherited shell tracing before any credentials or data are handled.
set +x
set -euo pipefail
umask 077

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
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
  checks_dir="$work_dir/checks"
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
  local uuid_pattern='^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
  local timestamp_pattern='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  local version_pattern='^[0-9][A-Za-z0-9._-]*$'

  if [[ ! ${PRODUCTION_SUBSCRIPTION_ID:-} =~ $uuid_pattern ]]; then
    fail 'A production subscription UUID is required.'
  fi
  if [[ ! ${PITR_TIMESTAMP:-} =~ $timestamp_pattern ]]; then
    fail 'PITR_TIMESTAMP must use YYYY-MM-DDTHH:mm:ssZ.'
  fi
  if [[ ! ${ANONYMISATION_VERSION:-} =~ $version_pattern || ${ANONYMISATION_VERSION:-} == *SNAPSHOT* ]]; then
    fail 'Specify an exact released anonymisation package version; snapshots are not supported.'
  fi
  if [[ ${REPOSITORY_URL:-} != https://* ]]; then
    fail 'REPOSITORY_URL must use HTTPS.'
  fi
  if [[ ! ${PUBLISH_DUMP:-false} =~ ^([Tt]rue|[Ff]alse)$ ]]; then
    fail 'PUBLISH_DUMP must be true or false.'
  fi
  : "${POSTGRESQL_HOME:?POSTGRESQL_HOME is required}"
}

# -----------------------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------------------
check_dependencies() {
  local tool
  postgres_bin="${POSTGRESQL_HOME}/bin"
  export POSTGRESQL_HOME
  export PATH="${postgres_bin}:${PATH}"
  export LD_LIBRARY_PATH="${POSTGRESQL_HOME}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

  for tool in az curl tar flock openssl; do
    if ! command -v "$tool" >/dev/null; then
      fail "Missing required tool: ${tool}."
    fi
  done

  for tool in psql pg_dump pg_restore; do
    if [[ ! -x "$postgres_bin/$tool" ]]; then
      fail "Missing PostgreSQL client: ${postgres_bin}/${tool}."
    fi
    if [[ ! $("$postgres_bin/$tool" --version) =~ PostgreSQL\)\ 15\. ]]; then
      fail "${tool} must be PostgreSQL 15."
    fi
  done
}

# -----------------------------------------------------------------------------
# Workspace setup and cleanup
# -----------------------------------------------------------------------------
remove_temporary_database() {
  local existing_server

  if [[ ! -f $restore_marker ]]; then
    return 0
  fi
  if ! az account set --subscription "$PRODUCTION_SUBSCRIPTION_ID"; then
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

# Recheck ownership under the lock so the separate cleanup task cannot delete
# another run's report when recovering from an interrupted process.
remove_checks_report() {
  local report_owner

  if [[ ${checks_lock_held:-false} != true ]]; then
    if [[ ! -d $work_dir || ! -f ${checks_report}.lock ]]; then
      return 0
    fi
    if ! report_owner=$(cat "${checks_report}.lock"); then
      return 1
    fi
    if [[ $report_owner != "$RUN_ID" ]]; then
      return 0
    fi
    if ! exec 9>>"${checks_report}.lock"; then
      return 1
    fi
    if ! flock -n 9; then
      echo "Checks report is still in use; inspect ${checks_report} manually." >&2
      return 1
    fi
    if ! report_owner=$(cat "${checks_report}.lock"); then
      return 1
    fi
    if [[ $report_owner != "$RUN_ID" ]]; then
      return 0
    fi
    checks_lock_held=true
  fi

  rm -f -- "$checks_report"
}

cleanup() {
  local preserve_checks=${1:-false}
  local status=0

  # Remove local data before waiting for Azure server deletion.
  if ! remove_checks_report; then
    status=1
  fi
  if ! rm -rf -- "$work_dir/work"; then
    status=1
  fi
  if [[ $preserve_checks != true ]]; then
    if ! rm -rf -- "$checks_dir"; then
      status=1
    fi
  fi
  if ! remove_temporary_database; then
    status=1
  fi
  if (( status != 0 )); then
    rm -rf -- "$checks_dir" || status=1
  fi
  if (( status != 0 )); then
    echo "Cleanup failed. Check ${work_dir}, ${checks_report} and temporary server ${resource_group}/${temporary_server} manually." >&2
  fi
  return "$status"
}

on_exit() {
  local status=$?
  local preserve_checks=false
  trap - EXIT

  if (( status == 0 )); then
    preserve_checks=true
  fi
  if ! cleanup "$preserve_checks"; then
    status=1
  fi
  if (( status == 0 )); then
    echo '##vso[task.setvariable variable=anonymisationChecksAvailable]true'
  fi
  exit "$status"
}

prepare_workspace() {
  # The legacy package writes a fixed CSV path. Lock it so concurrent runs on
  # this host cannot read each other's report, and discard any stale report.
  exec 9>>"${checks_report}.lock"
  if ! flock -n 9; then
    fail 'Another anonymisation is using the same checks report path.'
  fi
  if [[ -e $work_dir ]]; then
    fail "Run directory already exists: ${work_dir}. Use a new job attempt."
  fi
  mkdir -p "$package_dir" "$checks_dir"

  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  checks_lock_held=true
  printf '%s\n' "$RUN_ID" > "${checks_report}.lock"
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
  local source_host
  export PGSSLMODE=require PGCONNECT_TIMEOUT=10 PGPORT=5432 PGDATABASE=mojdb
  az account set --subscription "$PRODUCTION_SUBSCRIPTION_ID"

  source_host=$(read_secret dapdb-postgresql-fqdn)
  if [[ $source_host != "${source_server}.postgres.database.azure.com" ]]; then
    fail 'DAPDB hostname does not match the expected new production server.'
  fi

  admin_user=$(read_secret dapdb-postgresql-admin-username)
  admin_password=$(read_secret dapdb-postgresql-admin-password)
  anonymisation_user=${ANONYMISATION_USER:-$admin_user}
  anonymisation_password=$(read_secret "${ANONYMISATION_PASSWORD_SECRET:-dapdb-postgresql-admin-password}")
  if [[ -z $admin_user || -z $admin_password || -z $anonymisation_password ]]; then
    fail 'Database credentials must not be empty.'
  fi

  encryption_password=$(read_secret "${ENCRYPTION_PASSWORD_SECRET:-anonymised-db-dump-encryption-password}")
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
  local package_url="${REPOSITORY_URL%/}/${artifact_path}/${ANONYMISATION_VERSION}/${package_name}"
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
  local pipeline_status=(0 0)
  local diagnostics_file="$checks_dir/anonymisation_${RUN_ID}.log.enc"

  echo "Running anonymisation package ${ANONYMISATION_VERSION} against ${temporary_server}."
  # Capture both output streams before they reach the pipeline log. Do not
  # create a plaintext log, even when the anonymiser prints errors or secrets.
  (
    cd "$package_dir" || exit 1
    export PGHOST="$temporary_host" PGUSER="$anonymisation_user" PGPASSWORD="$anonymisation_password"
    "$anonymiser" "$temporary_host"
  ) 2>&1 |
    ENCPASSWORD="$encryption_password" openssl enc \
      "${encryption_options[@]}" \
      -out "$diagnostics_file" 2>/dev/null || pipeline_status=("${PIPESTATUS[@]}")

  if (( pipeline_status[1] != 0 )); then
    fail 'Could not encrypt anonymisation diagnostics; no dump will be uploaded.'
  fi
  if (( pipeline_status[0] != 0 )); then
    fail "Anonymisation failed with exit status ${pipeline_status[0]}; no dump will be uploaded."
  fi
  if [[ ! -s $checks_report ]]; then
    fail 'Anonymisation did not produce a nonempty checks CSV; no dump will be uploaded.'
  fi
}

# -----------------------------------------------------------------------------
# Checks report encryption
# -----------------------------------------------------------------------------
encrypt_checks_report() {
  local encrypted_report="$checks_dir/rota_anonymised_database_checks_${RUN_ID}.csv.enc"

  if ! ENCPASSWORD="$encryption_password" openssl enc \
    "${encryption_options[@]}" \
    -in "$checks_report" \
    -out "$encrypted_report" 2>/dev/null; then
    fail 'Could not encrypt the checks report; no dump will be uploaded.'
  fi
  if [[ ! -s $encrypted_report ]]; then
    fail 'Checks report encryption produced an empty file; no dump will be uploaded.'
  fi
  if ! rm -f -- "$checks_report"; then
    fail 'Could not remove the plaintext checks report; no dump will be uploaded.'
  fi
}

# -----------------------------------------------------------------------------
# Dump creation and encryption
# -----------------------------------------------------------------------------
create_encrypted_dump() {
  local pipeline_status=(0 0)
  blob_name="mojdb_anonymised_$(date -u +%Y-%m-%d_%H-%M-%S)_${RUN_ID}.backup.enc"
  encrypted_dump_file="$work_dir/work/$blob_name"

  # pipefail stops the run if either pg_dump or OpenSSL fails. Plaintext goes
  # directly through the pipe and is never written to a backup file.
  PGPASSWORD="$admin_password" "$postgres_bin/pg_dump" \
    -w \
    --host="$temporary_host" \
    --username="$admin_user" \
    --dbname=mojdb \
    --schema=public \
    -Fc 2>/dev/null |
    ENCPASSWORD="$encryption_password" openssl enc \
      "${encryption_options[@]}" \
      -out "$encrypted_dump_file" 2>/dev/null || pipeline_status=("${PIPESTATUS[@]}")

  if (( pipeline_status[1] != 0 )); then
    fail 'Backup encryption failed; no dump will be uploaded.'
  fi
  if (( pipeline_status[0] != 0 )); then
    fail 'Database dump failed; no dump will be uploaded.'
  fi
  if [[ ! -s $encrypted_dump_file ]]; then
    fail 'OpenSSL produced an empty encrypted dump.'
  fi
}

# -----------------------------------------------------------------------------
# Encrypted dump validation
# -----------------------------------------------------------------------------
validate_encrypted_dump() {
  if ! ENCPASSWORD="$encryption_password" openssl enc \
    -d \
    "${encryption_options[@]}" \
    -in "$encrypted_dump_file" 2>/dev/null |
    (
      "$postgres_bin/pg_restore" --list >/dev/null 2>/dev/null || exit 1
      # pg_restore only reads the archive contents list. Drain the remaining
      # stream so OpenSSL can finish without a broken pipe on large backups.
      cat >/dev/null
    ); then
    fail 'Encrypted backup validation failed; no dump will be uploaded.'
  fi
}

# -----------------------------------------------------------------------------
# Blob upload and verification
# -----------------------------------------------------------------------------
publication_enabled() {
  [[ ${PUBLISH_DUMP:-false} == [Tt]rue ]]
}

upload_dump() {
  local remote_size local_size
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

  remote_size=$(az storage blob show \
    --account-name "$storage_account" \
    --container-name "$container" \
    --name "$blob_name" \
    --auth-mode login \
    --query properties.contentLength \
    --output tsv)
  local_size=$(wc -c < "$encrypted_dump_file" | tr -d '[:space:]')
  if [[ $remote_size != "$local_size" ]]; then
    fail 'Uploaded blob size does not match the local dump; investigate the blob before distribution.'
  fi

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
  check_dependencies
  prepare_workspace
  load_credentials
  check_source_server
  download_package
  restore_database
  wait_for_database
  run_anonymisation
  encrypt_checks_report
  create_encrypted_dump
  validate_encrypted_dump

  if publication_enabled; then
    upload_dump
  else
    echo 'Validation run complete. Upload is disabled; review the checks artifact and package before enabling publishDump.'
  fi
}

main "$@"
