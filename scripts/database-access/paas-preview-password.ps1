$ErrorActionPreference = 'Stop'

$AKS_SUBSCRIPTION = 'DCD-CFTAPPS-DEV'
$AKS_RESOURCE_GROUP = 'cft-preview-00-rg'
$AKS_CLUSTER = 'cft-preview-00-aks'
$KUBERNETES_NAMESPACE = 'rota'

# Ensure all the required tools are installed
foreach ($requiredCommand in 'az', 'kubectl', 'kubelogin') {
    if (-not (Get-Command $requiredCommand -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine('You must have installed Azure CLI: winget install --exact --id Microsoft.AzureCLI')
        [Console]::Error.WriteLine('You must have installed Kubectl:   winget install --exact --id Kubernetes.kubectl')
        [Console]::Error.WriteLine('You must have installed Kubelogin: winget install --exact --id Microsoft.Azure.Kubelogin')
        exit 1
    }
}

# Ensure logged into azure cli and if not prompt user to authenticate
az account show *> $null
if ($LASTEXITCODE -ne 0) {
    az login --output none
}

# Add the preview AKS context when it is not already configured locally
if ((kubectl config get-contexts $AKS_CLUSTER -o name 2>$null) -ne $AKS_CLUSTER) {
    az aks get-credentials --subscription $AKS_SUBSCRIPTION --resource-group $AKS_RESOURCE_GROUP --name $AKS_CLUSTER --output none
}

# Configure only the preview context to use the current Azure CLI session
kubelogin convert-kubeconfig --context $AKS_CLUSTER -l azurecli

# Output only the hmcts administrator password so callers can capture it
Write-Output "Preview Password: $(kubectl --context $AKS_CLUSTER -n $KUBERNETES_NAMESPACE get secret postgres -o 'go-template={{index .data "PASSWORD" | base64decode}}{{"\n"}}')"
