# Azure Catalyst walkthrough (portal + appliance)

Catalyst still runs on the Azure Migrate engine, and some blades and Learn pages still say "Azure Migrate". Both names are given where they differ. Run `./scripts/Get-LabCredentials.ps1` to see every password mentioned below; on the host they're in `C:\Lab\.lab\secrets.json`.

## 1. Create a Catalyst project (~2 min)

1. In the Azure portal, search **Azure Catalyst** (or **Azure Migrate**). Open **Servers, databases and web apps**, then select **Create project**.
2. Choose your subscription and a resource group (the lab RG is fine). Name the project, for example `catlab-catalyst`, and pick a geography. Connectivity: **Public endpoint**.

## 2a. Discover with the appliance: performance data, software inventory, dependency map

1. Generate the key. In the project, go to **Discover** → *Are your servers virtualized?* **Yes, with Hyper-V**. Name the appliance (≤14 alphanumeric characters, for example `catlabapp01`), select **Generate key**, and copy the key.
2. Open the appliance:
   - Portal → lab RG → **catlab-hv01** → **Connect → Bastion**, signing in as `labadmin` with the host password.
   - On the host, open **Hyper-V Manager** → **CAT-APPLIANCE** → **Connect**, signing in as `Administrator` with the guest password.
3. **Register it.** Open **Azure Migrate Appliance Configuration Manager** (desktop shortcut, or `https://localhost:44368`).
   - Let the prerequisite checks and the auto-update finish.
   - Paste the key → **Verify** → **Login**, and complete the device-code sign-in with your Azure account.
4. **Hyper-V host.** Under *Add credentials*, choose Hyper-V host, user `catdiscovery`, password `DiscoveryPassword`. Then *Add discovery source*: IP `192.168.100.1`.
5. **Guest credentials** (for software inventory and the dependency map):
   * Domain credentials: `CATLAB\Administrator` / guest password, which covers all Windows servers.
   * Linux (non-domain): `labadmin` / guest password.
6. Turn on **dependency analysis**, then select **Start discovery**. Servers appear in about 15 minutes, and dependency data builds over the following hours.

## 2b. Discover from the CMDB: CSV import (no appliance needed)

1. Build the CMDB from your machine (Cloud Shell works too):
   ```powershell
   ./scripts/05-Build-Cmdb.ps1
   ```
   This writes:
   * `cmdb/cmdb.csv`: one configuration item per server, with hardware facts from Hyper-V/KVP plus application, owner, environment, migration intent and target.
   * `cmdb/cmdb_rel_ci.csv`: "Depends on::Used by" relationships.
   * `cmdb/catalyst-import.csv`: the 15 workloads in Catalyst's import template.
2. Upload it: **Discover** → **Import using CSV**, upload `catalyst-import.csv`, then **Import**. The servers appear under *Discovered servers* → **Import based**.

CSV import gives you an assessment without an appliance. It has no performance history and no dependency map, and Catalyst won't migrate imported records. Migration still works through the replication provider (step 4), which discovers the VMs directly from the Hyper-V host.

## 3. Assess, then plan with the Catalyst agent

* **Assess → Azure VM**: choose the target region, sizing **As on-premises** (or performance-based once the appliance has collected data), and create a group (for example *storefront* = WEB01, LNX01, API01, CACHE01, SQL01, MQ01, ORDERS01).
* Open the **dependency map** to show how one group pulls in others: storefront → inventory API → PostgreSQL, and the order worker → file server.
* Try the **Catalyst agent** (preview), for example: *"Plan migration waves for the storefront application"* or *"Which servers should be retired?"*. The CMDB intents (Retain/Retire) give it something to reason about.

## 4. Prepare replication (~10 min)

1. Go to **Migration tools** (*Migrate and modernize*) → **Discover** → **Yes, with Hyper-V**, choose the target region (the lab region), then **Create resources**.
2. Under **Prepare Hyper-V host servers**, download the **registration key file** (`*.VaultCredentials`, valid for 5 days).
3. From your machine, run:
   ```powershell
   ./scripts/04-Install-ReplicationProvider.ps1 -KeyFile <path to .VaultCredentials>
   ```
   This downloads the Microsoft-signed provider onto the host, installs it and registers it.
4. In the portal, select **Finalize registration**. `catlab-hv01` should show as connected.

## 5. Replicate and test-migrate (~45–90 min)

1. Go to **Replicate**, choose source **Hyper-V**, and pick servers (for example CAT-WEB01 and CAT-LNX01). Set:
   * Target: the lab RG and VNet `catlab-vnet`, subnet **snet-migrated**.
   * Size: a 2-vCPU size such as `Standard_B2s` (mind your regional vCPU quota).
2. Wait for **Protected**, then run **Test migration** for one VM into `catlab-vnet` / `snet-migrated`.
3. Run `./tests/Test-CatalystLab.ps1 -Phase Replication,TestMigration`. The host fetches the migrated VM's page over the VNet.
4. **Clean up test migration** when you're done.
