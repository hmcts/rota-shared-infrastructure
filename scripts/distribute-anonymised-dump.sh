#!/usr/bin/env bash
set -euo pipefail

container=anonymised-db-dumps
source_account=rotasademo # change to prod once created
destination_account=rotasaat

if [[ ! ${BLOB_NAME:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo 'BLOB_NAME must be a single filename containing only letters, digits, dots, underscores or hyphens.' >&2
  exit 1
fi

blob_exists() {
  # Convert the boolean to a lowercase string for consistent TSV comparisons.
  az storage blob exists \
    --account-name "$1" \
    --container-name "$container" \
    --name "$BLOB_NAME" \
    --auth-mode login \
    --query 'to_string(exists)' \
    --output tsv
}

exists=$(blob_exists "$destination_account")
if [[ $exists == true ]]; then
  echo "Destination blob ${destination_account}/${container}/${BLOB_NAME} already exists." >&2
  exit 1
fi
if [[ $exists != false ]]; then
  echo "Could not confirm that ${destination_account}/${container}/${BLOB_NAME} is absent." >&2
  exit 1
fi

if ! command -v azcopy >/dev/null 2>&1; then
  azcopy_dir=$(mktemp -d)
  trap 'rm -rf "$azcopy_dir"' EXIT
  curl --fail --location --silent --show-error \
    https://aka.ms/downloadazcopy-v10-linux \
    --output "$azcopy_dir/azcopy.tar.gz"
  tar -xzf "$azcopy_dir/azcopy.tar.gz" -C "$azcopy_dir"
  azcopy=$(find "$azcopy_dir" -type f -name azcopy -print -quit)
  if [[ -z $azcopy ]]; then
    echo 'AzCopy was not found in the downloaded archive.' >&2
    exit 1
  fi
else
  azcopy=$(command -v azcopy)
fi

export AZCOPY_AUTO_LOGIN_TYPE=AZCLI
AZCOPY_TENANT_ID=$(az account show --query tenantId --output tsv)
export AZCOPY_TENANT_ID

source_url="https://${source_account}.blob.core.windows.net/${container}/${BLOB_NAME}"
destination_url="https://${destination_account}.blob.core.windows.net/${container}/${BLOB_NAME}"
"$azcopy" copy "$source_url" "$destination_url" --from-to=BlobBlob --overwrite=false

copied=$(blob_exists "$destination_account")
if [[ $copied != true ]]; then
  echo "Copy did not create ${destination_account}/${container}/${BLOB_NAME}." >&2
  exit 1
fi
