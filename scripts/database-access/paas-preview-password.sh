#!/bin/bash
set -e

readonly AKS_SUBSCRIPTION="DCD-CFTAPPS-DEV"
readonly AKS_RESOURCE_GROUP="cft-preview-00-rg"
readonly AKS_CLUSTER="cft-preview-00-aks"
readonly KUBERNETES_NAMESPACE="rota"

# Ensure all the required tools are installed
for required_command in az kubectl kubelogin; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo >&2 "You must have installed Azure CLI: brew install azure-cli"
    echo >&2 "You must have installed Kubectl:   brew install kubectl"
    echo >&2 "You must have installed Kubelogin: brew install Azure/kubelogin/kubelogin"
    exit 1
  fi
done

# Ensure logged into azure cli and if not prompt user to authenticate
if ! az account show >/dev/null 2>&1; then
  az login --output none
fi

# Add the preview AKS context when it is not already configured locally
if [[ "$(kubectl config get-contexts "${AKS_CLUSTER}" -o name 2>/dev/null)" != "${AKS_CLUSTER}" ]]; then
  az aks get-credentials --subscription "${AKS_SUBSCRIPTION}" --resource-group "${AKS_RESOURCE_GROUP}" --name "${AKS_CLUSTER}" --output none
fi

# Configure only the preview context to use the current Azure CLI session
kubelogin convert-kubeconfig --context "${AKS_CLUSTER}" -l azurecli

# Output only the hmcts administrator password so callers can capture it
echo -e "Preview Password: $(kubectl --context "${AKS_CLUSTER}" -n "${KUBERNETES_NAMESPACE}" get secret postgres -o go-template='{{index .data "PASSWORD" | base64decode}}{{"\n"}}')"
