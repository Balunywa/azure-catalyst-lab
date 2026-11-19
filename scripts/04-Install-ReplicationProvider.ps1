<#
.SYNOPSIS
  Step 4: install the Hyper-V replication provider on the host and register it with the Catalyst project's vault.
.PARAMETER KeyFile
  The *.VaultCredentials registration key downloaded from the portal (Migration tools > Discover > Hyper-V >
  "Prepare Hyper-V host servers"). Valid for 5 days.
.EXAMPLE
  ./scripts/04-Install-ReplicationProvider.ps1 -KeyFile "$HOME\Downloads\catlab-catalyst-MigrateVault.VaultCredentials"
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateScript({ Test-Path $_ -PathType Leaf })][string]$KeyFile)

. "$PSScriptRoot/LabCommon.ps1"
$name = Split-Path $KeyFile -Leaf
if ($name -notlike '*.VaultCredentials') { throw "Expected a *.VaultCredentials file, got $name" }
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path $KeyFile)))

Write-Step "Copying $name to the host"
Invoke-LabHost -Command @"
New-Item -ItemType Directory -Force C:\Lab\replication | Out-Null
icacls C:\Lab\replication /inheritance:r /grant 'Administrators:(OI)(CI)F' /grant 'SYSTEM:(OI)(CI)F' | Out-Null
Get-ChildItem C:\Lab\replication -Filter *.VaultCredentials | Remove-Item -Force
[IO.File]::WriteAllBytes('C:\Lab\replication\$name', [Convert]::FromBase64String('$b64'))
'key file bytes: ' + (Get-Item 'C:\Lab\replication\$name').Length
"@ | ForEach-Object { "    $_" }

Write-Step 'Installing + registering the Azure Site Recovery provider (Hyper-V replication)'
Invoke-LabHostScript -Name '40-Install-ReplicationProvider.ps1' | ForEach-Object { "    $_" }
Write-Ok 'Now select "Finalize registration" in the portal (docs/portal-steps.md, part D).'
