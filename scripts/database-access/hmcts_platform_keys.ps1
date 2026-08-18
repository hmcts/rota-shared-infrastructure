$ErrorActionPreference = 'Stop'

# Ensure azure cli tools are installed
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('You must have installed Azure CLI: winget install --exact --id Microsoft.AzureCLI')
    exit 1
}

# Ensure ssh extension for the azure cli is installed
az extension show --name ssh *> $null
if ($LASTEXITCODE -ne 0) {
    az extension add --name ssh
}

# Ensure logged into azure cli and if not prompt user to authenticate
az account show *> $null
if ($LASTEXITCODE -ne 0) {
    az login --output none
}

# Delete any existing keys and then recreate them in the default directory
$keysDestination = Join-Path $HOME '.ssh\az_ssh_config\platform.hmcts.net'
if (Test-Path -LiteralPath $keysDestination) {
    Remove-Item -LiteralPath $keysDestination -Recurse -Force
}

az ssh config --ip '*.platform.hmcts.net' --file 'NUL' --keys-destination-folder $keysDestination
