#!/usr/bin/env bash
set -euo pipefail

account=rotasademo
container=anonymised-db-dumps

test_dir=$(mktemp -d "${AGENT_TEMPDIRECTORY:-${TMPDIR:-/tmp}}/blob-permissions.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

blob_name="permissions-test-$(date -u +%Y%m%dT%H%M%SZ)-${test_dir##*/}.txt"
source_file="$test_dir/original.txt"
download_file="$test_dir/downloaded.txt"

printf 'Blob upload/download permissions test\nPipeline run: %s\nBlob: %s\n' \
  "${BUILD_BUILDID:-local}" "$blob_name" > "$source_file"

echo 'Azure identity used by the service connection:'
az account show \
  --query '{identity:user.name,type:user.type,tenantId:tenantId}' \
  --output json

echo "Uploading test file to https://${account}.blob.core.windows.net/${container}/${blob_name}"
az storage blob upload \
  --account-name "$account" \
  --container-name "$container" \
  --name "$blob_name" \
  --file "$source_file" \
  --type block \
  --overwrite false \
  --auth-mode login \
  --only-show-errors \
  --output none

echo 'Downloading the uploaded blob to verify read access.'
az storage blob download \
  --account-name "$account" \
  --container-name "$container" \
  --name "$blob_name" \
  --file "$download_file" \
  --auth-mode login \
  --only-show-errors \
  --output none

if ! cmp -s "$source_file" "$download_file"; then
  echo 'Verification failed: downloaded contents differ from the original file.' >&2
  exit 1
fi

echo 'Upload and download permissions verified; file contents match.'
echo "Test blob retained for inspection: https://${account}.blob.core.windows.net/${container}/${blob_name}"
