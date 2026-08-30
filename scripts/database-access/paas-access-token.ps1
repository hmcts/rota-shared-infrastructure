$ErrorActionPreference = 'Stop'

# Ensure azure cli tools are installed
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('You must have installed Azure CLI: winget install --exact --id Microsoft.AzureCLI')
    exit 1
}

# Ensure logged into azure cli and if not prompt user to authenticate
az account show *> $null
if ($LASTEXITCODE -ne 0) {
    az login --output none
}

# Output access token and its expiry which is the password to use to connect to the databases
Write-Output 'Access Token:'
az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv
Write-Output 'Expires On:'
az account get-access-token --resource-type oss-rdbms --query expiresOn -o tsv
