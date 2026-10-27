#!/usr/bin/env bash
set -euo pipefail

source_account=rotasademo
destination_environment=aat
destination_account="rotasa${destination_environment}"
container=anonymised-db-dumps
script_dir=$(dirname -- "${BASH_SOURCE[0]}")

test_dir=$(mktemp -d "${AGENT_TEMPDIRECTORY:-${TMPDIR:-/tmp}}/blob-copy.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

echo 'Testing the distribution script with Demo as the source and AAT as the only destination.'
DESTINATION_ENVIRONMENTS="$destination_environment" bash "$script_dir/distribute-anonymised-dump.sh"

echo 'Downloading the Demo source blob to verify the copied contents.'
az storage blob download \
  --account-name "$source_account" \
  --container-name "$container" \
  --name "$BLOB_NAME" \
  --file "$test_dir/source.txt" \
  --auth-mode login \
  --only-show-errors \
  --output none

echo 'Downloading the AAT copy for comparison.'
az storage blob download \
  --account-name "$destination_account" \
  --container-name "$container" \
  --name "$BLOB_NAME" \
  --file "$test_dir/destination.txt" \
  --auth-mode login \
  --only-show-errors \
  --output none

if ! cmp -s "$test_dir/source.txt" "$test_dir/destination.txt"; then
  echo 'Verification failed: the AAT copy differs from the Demo source.' >&2
  exit 1
fi

echo 'Demo-to-AAT copy verified; file contents match.'
echo "Source retained: https://${source_account}.blob.core.windows.net/${container}/${BLOB_NAME}"
echo "Copy retained: https://${destination_account}.blob.core.windows.net/${container}/${BLOB_NAME}"
