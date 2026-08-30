#!/bin/bash
set -e

# Ensure azure cli tools are installed
if ! command -v az >/dev/null 2>&1; then
  echo >&2 "You must have installed Azure CLI: brew install azure-cli"
  exit 1
fi

# Ensure ssh extension for the azure cli is installed
if ! az extension show --name ssh >/dev/null 2>&1; then
  az extension add --name ssh
fi

# Ensure logged into azure cli and if not prompt user to authenticate
if ! az account show >/dev/null 2>&1; then
  az login --output none
fi

# Delete any existing keys and then recreate them in the default directory
KEYS_DESTINATION=~/.ssh/az_ssh_config/platform.hmcts.net
rm -fr $KEYS_DESTINATION
az ssh config --ip \*.platform.hmcts.net --file /dev/null --keys-destination-folder $KEYS_DESTINATION
