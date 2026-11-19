<#
.SYNOPSIS
  One command to deploy the Azure Catalyst end-to-end Hyper-V lab.
.DESCRIPTION
  Preflight (login, providers, VM size + vCPU quota) -> resource group -> infra/azuredeploy.json.
  The host VM then builds the whole lab by itself (~100 min): 15-server company + Catalyst appliance.
  Works from Windows/macOS/Linux PowerShell 7 or Azure Cloud Shell; you can close the session after the
  deployment step - the build runs inside Azure. Check on it any time with ./scripts/Get-LabStatus.ps1.
.EXAMPLE
  ./Deploy-CatalystLab.ps1
.EXAMPLE
  ./Deploy-CatalystLab.ps1 -Location westus3 -ResourceGroup rg-catalyst-demo -Wait
.EXAMPLE
  ./Deploy-CatalystLab.ps1 -AcceptSqlExpressLicense      # also installs SQL Server 2022 Express on CAT-SQL01
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$Location = 'eastus2',
    [string]$ResourceGroup = 'rg-catalyst-lab',
    [string]$VmSize = 'Standard_E8s_v6',
    [switch]$AcceptSqlExpressLicense,
    [ValidateSet('Developer', 'Basic')][string]$BastionSku = 'Developer',
    [string]$RepoUrl,
    [string]$RepoRef,
    [switch]$Wait,
    [switch]$SkipPreflight
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts/LabCommon.ps1')
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7+ is required (Azure Cloud Shell has it).' }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) is required: https://aka.ms/installazurecli' }

# --- Subscription --------------------------------------------------------------------------------
Write-Step 'Azure login'
if ($SubscriptionId) { az account set --subscription $SubscriptionId | Out-Null; if ($LASTEXITCODE) { throw "Cannot select subscription $SubscriptionId" } }
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { throw "Not logged in. Run 'az login' first." }
Write-Ok "Subscription: $($acct.name) ($($acct.id))"
$defaults = Get-Content (Join-Path $PSScriptRoot 'lab.settings.json') -Raw | ConvertFrom-Json
if (-not $RepoUrl) { $RepoUrl = $defaults.Repo.Url }
if (-not $RepoRef) { $RepoRef = $defaults.Repo.Ref }
Set-LabLocalSettings @{ SubscriptionId = $acct.id; ResourceGroup = $ResourceGroup; Location = $Location; HostVmSize = $VmSize; AcceptSqlExpressLicense = [bool]$AcceptSqlExpressLicense }
$sub = $acct.id

# --- Preflight -----------------------------------------------------------------------------------
if (-not $SkipPreflight) {
    Write-Step "Preflight: $VmSize in $Location"
    foreach ($ns in 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Migrate', 'Microsoft.OffAzure', 'Microsoft.RecoveryServices') {
        $st = az provider show -n $ns --subscription $sub --query registrationState -o tsv 2>$null
        if ($st -ne 'Registered') { az provider register -n $ns --subscription $sub | Out-Null; Write-Ok "registering provider $ns" }
    }
    $sku = az vm list-skus -l $Location --size $VmSize --resource-type virtualMachines --subscription $sub -o json 2>$null |
        ConvertFrom-Json | Where-Object name -eq $VmSize | Select-Object -First 1
    if (-not $sku) { throw "$VmSize is not offered in $Location. Try -Location eastus2/westus3/northeurope or -VmSize Standard_E8s_v5." }
    if ($sku.restrictions | Where-Object { $_.type -eq 'Location' }) { throw "$VmSize is restricted for this subscription in $Location ($($sku.restrictions[0].reasonCode))." }
    $vcpu = [int](($sku.capabilities | Where-Object name -eq 'vCPUs').value)
    $usage = az vm list-usage -l $Location --subscription $sub -o json | ConvertFrom-Json
    $total = $usage | Where-Object { $_.name.value -eq 'cores' }
    $fam   = $usage | Where-Object { $_.name.value -eq $sku.family }
    $freeTotal = [int]$total.limit - [int]$total.currentValue
    $freeFam   = [int]$fam.limit - [int]$fam.currentValue
    if ($freeTotal -lt $vcpu -or $freeFam -lt $vcpu) {
        throw "Not enough vCPU quota in ${Location}: need $vcpu, free regional=$freeTotal, free $($sku.family)=$freeFam. Request more at https://aka.ms/quotas or pick another region/size."
    }
    Write-Ok "$VmSize ($vcpu vCPU) available; quota free: regional $freeTotal, $($sku.family) $freeFam"
    if ($freeTotal - $vcpu -lt 2) { Write-Warning "After the host there are $($freeTotal - $vcpu) vCPUs left; test migrations need 2+ (request more quota for that step)." }
}

# --- Deploy --------------------------------------------------------------------------------------
$sec = Get-LabSecrets
Write-Step "Resource group $ResourceGroup"
az group create -n $ResourceGroup -l $Location --subscription $sub --tags purpose=azure-catalyst-lab -o none
if ($LASTEXITCODE) { throw 'Resource group creation failed' }

function Invoke-LabDeployment([string]$Bastion) {
    $params = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'
        parameters = @{
            location = @{ value = $Location }; vmSize = @{ value = $VmSize }; adminPassword = @{ value = $sec.HostAdminPassword }
            acceptSqlExpressLicense = @{ value = [bool]$AcceptSqlExpressLicense }; bastionSku = @{ value = $Bastion }
            repoUrl = @{ value = $RepoUrl }; repoRef = @{ value = $RepoRef }
        }
    }
    $pf = Join-Path $LabDir 'deploy.parameters.json'
    $params | ConvertTo-Json -Depth 6 | Set-Content $pf -Encoding utf8; Protect-LabFile $pf
    try {
        $out = az deployment group create -g $ResourceGroup -n catalyst-lab --subscription $sub `
            --template-file (Join-Path $PSScriptRoot 'infra/azuredeploy.json') --parameters "@$pf" -o json 2>&1
        [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); text = ($out | ForEach-Object { "$_" }) -join "`n" }
    } finally { Remove-Item $pf -ErrorAction SilentlyContinue }
}

Write-Step "Deploying host VM + network + Bastion ($BastionSku) - ~10 min"
$r = Invoke-LabDeployment $BastionSku
if (-not $r.ok -and $BastionSku -eq 'Developer' -and $r.text -match '(?i)bastion|Developer') {
    Write-Warning 'Bastion Developer SKU is not available here; retrying with Basic (~$0.19/hr).'
    $r = Invoke-LabDeployment 'Basic'
}
if (-not $r.ok) { throw "Deployment failed:`n$($r.text)" }
Write-Ok 'Infrastructure deployed; the VM is now building the lab (~100 min)'
Set-LabState @{ DeployedUtc = (Get-Date).ToUniversalTime().ToString('s') }

Write-Host @"

  What happens now (inside Azure - you can close this window):
    bootstrap -> reboot -> network -> images (9.5 GB download) -> 16 VMs -> AD -> apps -> Catalyst appliance

  Watch progress:      ./scripts/Get-LabStatus.ps1 -Wait
  Lab credentials:     ./scripts/Get-LabCredentials.ps1
  Validate when done:  ./tests/Test-CatalystLab.ps1
  Then follow:         docs/portal-steps.md  (create the Catalyst project, register the appliance)

"@ -ForegroundColor Yellow
if ($Wait) { & (Join-Path $PSScriptRoot 'scripts/Get-LabStatus.ps1') -Wait }
