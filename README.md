# Azure Catalyst end-to-end lab (Hyper-V)

Want to try **Azure Catalyst**, the agent-led successor to Azure Migrate announced at Microsoft Ignite 2026, on something that looks like a real customer estate? This repo deploys one with a single command. A Windows Server 2022 VM in Azure runs nested Hyper-V and builds a **15-server fictional company** inside itself: Active Directory, IIS and Linux apps, SQL Server, PostgreSQL, Redis, RabbitMQ, file shares and monitoring, all wired together with **live dependencies**. It also installs the **Catalyst / Azure Migrate appliance**, ready to register.

You can then try discovery, CMDB (CSV) import, dependency analysis, assessment, the Catalyst agent, and replication and test migration of real VMs back into Azure.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FBalunywa%2Fazure-catalyst-lab%2Fmain%2Finfra%2Fazuredeploy.json)

> Community lab, not an official Microsoft product. It uses evaluation software (see [Licensing](#licensing)).

---

## What you get

```
 Azure (your subscription)
 ┌──────────────────────────────────────────────────────────────────────────────────────┐
 │ catlab-hv01  Windows Server 2022 + Hyper-V   (Standard_E8s_v6, nested virtualization)│
 │   LabSwitch 192.168.100.0/24  (NAT + DHCP)        AD domain: catlab.local            │
 │                                                                                      │
 │   CAT-LNX01 public site/proxy ─► CAT-WEB01 storefront ─► CAT-API01 inventory API     │
 │                    │                 │  │  │                 │        │              │
 │                    ├► CAT-HRWEB01    │  │  └► CAT-MQ01 ◄── CAT-ORDERS01 worker       │
 │                    └► CAT-TIME01     │  └► CAT-CACHE01 (Redis) ◄┘       │            │
 │                          │           ▼                                  ▼            │
 │   CAT-BI01 reporting ─► CAT-SQL01 (SQL)   CAT-PGSQL01 (PostgreSQL) ◄─────┘           │
 │        └──────────────► CAT-FS01 file shares ◄── CAT-LEGACY01 EDI/FTP                │
 │   CAT-DC01 (AD DS/DNS) ◄── all Windows      CAT-MON01 (Prometheus) ──► all Linux     │
 │   CAT-APPLIANCE  Azure Catalyst (Azure Migrate) appliance, installed + ready         │
 └──────────────────────────────────────────────────────────────────────────────────────┘
   Azure Bastion (browser RDP)   No inbound ports open   snet-migrated: test-migration target
```

| Server | OS | App / role | CMDB intent → target |
|---|---|---|---|
| CAT-DC01 | WS2022 | AD DS + DNS (`catlab.local`) | Retain (extend AD to Azure) |
| CAT-FS01 | WS2022 | File server: Finance, Reports, Invoices, EDI-Inbox, HR | Migrate → Azure Files |
| CAT-SQL01 | WS2022 | SQL Server 2022 Express* (Storefront, Timesheets) | Migrate → Azure SQL MI |
| CAT-PGSQL01 | Debian 12 | PostgreSQL (inventory, hr, fulfillment) | Migrate → Azure Database for PostgreSQL |
| CAT-CACHE01 | Debian 12 | Redis | Migrate → Azure Cache for Redis |
| CAT-MQ01 | Debian 12 | RabbitMQ | Migrate |
| CAT-MON01 | Debian 12 | Prometheus | Retire → Azure Monitor |
| CAT-WEB01 | WS2022 | Storefront (IIS) | Migrate |
| CAT-HRWEB01 | WS2022 | HR portal (IIS) | Migrate |
| CAT-TIME01 | WS2022 | Timesheets (IIS) | Migrate |
| CAT-BI01 | WS2022 | Reporting | Retire → Power BI |
| CAT-LNX01 | Debian 12 | Public website + reverse proxy | Migrate |
| CAT-API01 | Debian 12 | Inventory API (Python → PostgreSQL + Redis) | Migrate |
| CAT-ORDERS01 | Debian 12 | Order worker (RabbitMQ → PostgreSQL, invoices → SMB) | Migrate |
| CAT-LEGACY01 | Debian 12 | Legacy EDI/FTP gateway | Retire |
| CAT-APPLIANCE | WS2022 | **Azure Catalyst / Azure Migrate appliance** | n/a |

\* SQL Server Express installs only if you opt in with `-AcceptSqlExpressLicense`, or `acceptSqlExpressLicense = true` in the portal, because that accepts the SQL Server license terms.

All dependencies are real connections: application traffic plus a tiny agent per server that keeps a session open to each upstream. Catalyst's agentless dependency analysis therefore draws a complete map. The estate is defined in [`lab.settings.json`](lab.settings.json) (`NestedVms`); edit it to change servers, apps or dependencies.

## Prerequisites

| Need | Details |
|---|---|
| Azure subscription | **Owner**, or Contributor + User Access Administrator. Catalyst appliance registration also needs permission to create Entra app registrations. |
| vCPU quota | **8 vCPUs** of the VM family in your region (default `Standard_E8s_v6`, family Esv6). Test migrations need **+2–4 more** in the same region. |
| Region | Any region with `Standard_E8s_v6` (or another Intel size with nested virtualization). Bastion Developer (free) isn't in every region; the script falls back to Basic. |
| Tools (CLI path only) | PowerShell 7 + Azure CLI, or just **Azure Cloud Shell**. |

**Cost:** about **$1.1/hour** while the host runs (E8s_v6 Windows + 512 GB Premium disk), and close to $0 when stopped (disks only). Stop it with `./scripts/99-Stop-Or-Remove-Lab.ps1 -Action Stop`.

## Deploy

### Option A: Deploy to Azure button
1. Click **Deploy to Azure** above, pick a subscription, a new resource group and a region, and set an admin password.
2. Select **Review + create**. Infrastructure takes about 10 minutes, then the VM **builds the lab by itself for about 100 minutes**.
3. Watch progress: Bastion into `catlab-hv01` and open `C:\Lab\status.json`. Logs are in `C:\Lab\logs`.
   Lab passwords are in `C:\Lab\.lab\secrets.json`, readable by admins only.

### Option B: one command (Cloud Shell or local PowerShell 7)
```bash
git clone https://github.com/Balunywa/azure-catalyst-lab.git
```
```bash
cd azure-catalyst-lab
```
```powershell
./Deploy-CatalystLab.ps1 -Location eastus2 -ResourceGroup rg-catalyst-lab
```
- It runs preflight checks first: login, resource providers, VM size in the region, vCPU quota.
- It generates the host admin password into `.lab/secrets.json`, which git ignores.
- After the ~10-minute deployment step you can close the session. The build runs inside Azure.

```powershell
./scripts/Get-LabStatus.ps1 -Wait          # build progress (9 stages)
./scripts/Get-LabCredentials.ps1           # every sign-in for the lab
./tests/Test-CatalystLab.ps1               # ~70 end-to-end checks
```

Build stages: `bootstrap → network → images (9.5 GB eval VHD) → render → create 16 VMs → AD DS → Windows apps + domain join → Linux apps → appliance`.

## Use it with Azure Catalyst

Step-by-step, with exact values: **[docs/portal-steps.md](docs/portal-steps.md)**

1. **Create a Catalyst project** in the portal (Azure Catalyst / Azure Migrate → Servers, databases and web apps).
2. **Discover**, either:
   - **Appliance:** Bastion → host → Hyper-V Manager → CAT-APPLIANCE. Register it with the project key, add the Hyper-V host `192.168.100.1` plus guest credentials, and turn on dependency analysis.
   - **CMDB import:** `./scripts/05-Build-Cmdb.ps1` builds a CMDB from the live estate (`cmdb/cmdb.csv` plus relationships). It also exports `cmdb/catalyst-import.csv` in Catalyst's import template; upload that under *Discover → Import using CSV*.
3. **Assess** the servers, explore the dependency map, and ask the **Catalyst agent** to plan migration waves.
4. **Migrate:** install the Hyper-V replication provider with `./scripts/04-Install-ReplicationProvider.ps1 -KeyFile <.VaultCredentials>`. Then replicate and **test-migrate** a VM into `snet-migrated`. `Test-CatalystLab.ps1` checks that the migrated app answers from Azure.

## Validation

`tests/Test-CatalystLab.ps1` runs about 70 checks across eight phases:
- **Infra / Host:** VM, NSG has no inbound rules, Bastion, Hyper-V, NAT, DHCP.
- **Nested:** all 16 VMs, each service port, each server's live dependency sessions, domain membership, the inventory API returning data from PostgreSQL + Redis, and the proxy chain.
- **Appliance:** services running and the configuration manager listening.
- **Discovery:** appliance and/or CSV import.
- **Assessment, Replication, TestMigration:** the migrated app answers from Azure.

Host checks run through **Azure Run Command**, so no inbound access is needed. Samples of the generated CMDB are in [`samples/`](samples).

## How it works

* **`infra/main.bicep`** (compiled to `infra/azuredeploy.json`) creates:
  - a VNet with a host subnet, a test-migration subnet and a Bastion subnet
  - an NSG with **no inbound rules**
  - the host VM (NVMe, 512 GB data disk) and Azure Bastion
  - a Custom Script Extension
* **`host/00-Bootstrap.ps1`** is what that extension runs. It downloads this repo onto the VM, generates the lab secrets, installs Hyper-V and DHCP, registers the `CatalystLabBuild` startup task and reboots.
* **`host/Start-LabBuild.ps1`** runs the stages in order, retries failures, resumes after reboots, and writes `C:\Lab\status.json`.
* **`roles/`** holds how each server is configured:
  - Linux: cloud-init with `role.sh` and the Python dependency agent.
  - Windows: `configure.ps1` over PowerShell Direct, plus the PowerShell dependency agent.
* **`scripts/`** are laptop/Cloud Shell helpers. They talk to the host only through Azure Run Command (HTTPS to ARM), which also works from locked-down corporate devices that block SSH/RDP.

## Tear down
```powershell
./scripts/99-Stop-Or-Remove-Lab.ps1 -Action Stop     # deallocate (keeps everything)
./scripts/99-Stop-Or-Remove-Lab.ps1 -Action Remove   # delete the resource group (stop replication first)
```
Also delete the Catalyst project's resource group if you created it somewhere else.

## Licensing

* This repo: [MIT](LICENSE).
* At build time the VM downloads, from the vendors:
  - **Windows Server 2022 Evaluation** (180 days). The unattended setup accepts its evaluation license.
  - **Debian 12** cloud images.
  - **Microsoft's Azure Migrate appliance installer**.
  - **SQL Server 2022 Express**, only if you opt in.
* By deploying, you accept those vendors' terms.

## Troubleshooting

See **[docs/troubleshooting.md](docs/troubleshooting.md)**: quota, region and Bastion SKU, resuming a failed stage, and the gotchas this lab already handles.
