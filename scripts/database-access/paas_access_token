#!/bin/bash
set -e

# Ensure azure cli tools are installed
if ! command -v az >/dev/null 2>&1; then
  echo >&2 "You must have installed Azure CLI: brew install azure-cli"
  exit 1
fi

# Ensure logged into azure cli and if not prompt user to authenticate
if ! az account show >/dev/null 2>&1; then
  az login --output none
fi

# Output access token and its expiry which is the password to use to connect to the databases
echo -e "Access Token:\n$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)"
echo -e "Expires On:\n$(az account get-access-token --resource-type oss-rdbms --query expiresOn -o tsv)"
