# Troubleshooting

## Deployment

| Symptom | Fix |
|---|---|
| `Not enough vCPU quota` (preflight) | Request quota for the VM family at https://aka.ms/quotas, or use another region (`-Location`) or size (`-VmSize Standard_E8s_v5`). |
| `... is not offered in <region>` | The size isn't in that region. Try `eastus2`, `westus3`, `northeurope`, or another Intel v5/v6 size with ≥ 8 vCPU / 64 GB. |
| Bastion deployment fails | The free Developer SKU isn't in every region. `Deploy-CatalystLab.ps1` retries with Basic automatically; in the portal, set `bastionSku = Basic`. |
| ARM64 or AMD sizes | Nested Hyper-V needs Intel VT-x exposed. Use Intel sizes (Dsv5/Esv5/Dsv6/Esv6). ARM64 laptops (for example Snapdragon) can't run this lab locally for the same reason. |

## Build (inside the VM)

* Progress is in `C:\Lab\status.json`, or run `./scripts/Get-LabStatus.ps1`. Per-stage logs are in `C:\Lab\logs\<stage>.log`, and bootstrap is in `C:\Lab\logs\00-bootstrap.log`.
* A stage is retried 3 times, after which the build stops with `state: failed`. Fix the cause, then resume. On the host (Bastion, elevated PowerShell), either:
  ```powershell
  Start-ScheduledTask CatalystLabBuild                       # resume from the failed stage
  powershell -File C:\Lab\repo\host\Start-LabBuild.ps1 -Reset members   # force a stage to re-run
  ```
* The `images` stage downloads a 9.5 GB Windows Server evaluation VHD. It usually takes 10–25 minutes.

### Gotchas the lab already handles (good to know if you adapt it)

| Issue | What the lab does |
|---|---|
| Debian's systemd-networkd sends a DUID DHCP client ID, so MAC reservations don't match. | The cloud-init network config sets `dhcp-identifier: mac` and matches `eth0` by name, not MAC, so it still works after migration to Azure. |
| On the WS2022 evaluation image, AD Web Services can come up **Disabled** after DC promotion. | Stage `dc` sets ADWS to Automatic and starts it. |
| Promotion with a DHCP-assigned DNS client can leave the DNS server with **no zones** (DNS event 708). | Stage `dc` creates the AD-integrated `catlab.local` and `_msdcs` zones, points the DC at itself and re-registers its SRV records. |
| `Set-NetConnectionProfile` fails on domain-joined guests. | Only *Public* networks are switched to Private. |
| The Azure Migrate installer prompts to remove IE and install Edge, then asks for confirmation. | IE is removed and Edge installed beforehand, and `Y` is piped to the single confirmation. The installer runs with `-Scenario HyperV -Cloud Public -PrivateEndpoint:$false`. |
| Windows PowerShell 5.1 `Get-Content -Raw` + `ConvertTo-Json` serialises strings as objects. | Role files are read with `[IO.File]::ReadAllText`. |
| Run Command returns at most 4 KB of output. | The inventory export is gzip + base64 encoded. |
| Corporate devices often block SSH/RDP to public IPs. | Every host action uses Azure Run Command, and the NSG has no inbound rules. |

## Catalyst / appliance

| Symptom | Fix |
|---|---|
| Appliance services stopped after registration starts | The appliance auto-updates its agents during the prerequisite checks. Wait, or run `Restart-Service amhv*, amsqlsvc, amwebappsvc` on CAT-APPLIANCE. |
| Hyper-V host validation fails | Use IP `192.168.100.1` with the `catdiscovery` account from `Get-LabCredentials.ps1`. WinRM 5985/5986 is open to the lab subnet only. |
| No dependency data | Add guest credentials (domain `CATLAB\Administrator`, Linux `labadmin`), then turn on dependency analysis. Data builds up over a few hours. |
| CSV import warnings about OS names | Catalyst recognises names that contain an entry from its supported OS list. `05-Build-Cmdb.ps1` writes `Microsoft Windows Server 2022 (64-bit)` and `Debian GNU/Linux 12`. |
| Test migration fails on quota | The host uses 8 vCPUs. Test-migrate one 2-vCPU VM at a time, or raise the regional quota. |
