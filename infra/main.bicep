// Azure Catalyst Hyper-V lab: one Windows Server 2022 VM with nested Hyper-V that builds a 15-server
// "on-premises" company inside itself (AD, IIS, SQL/PostgreSQL, Redis, RabbitMQ, ...) plus the Catalyst
// (Azure Migrate) appliance. The VM builds itself after deployment (~100 min); no inbound ports are opened.

@description('Region for every resource. The VM size must support nested virtualization (Intel Dsv5/Esv5/Dsv6/Esv6...).')
param location string = resourceGroup().location

@description('Host VM size: >= 8 vCPU and >= 64 GB RAM for the full 16-VM estate.')
param vmSize string = 'Standard_E8s_v6'

@description('Admin user for the host VM (sign in through Azure Bastion).')
param adminUsername string = 'labadmin'

@description('Admin password for the host VM.')
@secure()
param adminPassword string

@description('Prefix for resource names.')
param prefix string = 'catlab'

@description('Git repo that holds the lab scripts (the VM downloads it at deploy time).')
param repoUrl string = 'https://github.com/Balunywa/azure-catalyst-lab'

@description('Branch or tag of repoUrl to deploy.')
param repoRef string = 'main'

@description('Install SQL Server 2022 Express on CAT-SQL01. Setting true accepts the Microsoft SQL Server license terms.')
param acceptSqlExpressLicense bool = false

@description('Azure Bastion SKU. Developer is free but not offered in every region; use Basic if deployment fails.')
@allowed(['Developer', 'Basic'])
param bastionSku string = 'Developer'

@description('Data disk (GB) that holds the nested VMs.')
param dataDiskGB int = 512

var vmName = '${prefix}-hv01'
var rawBase = replace(repoUrl, 'https://github.com/', 'https://raw.githubusercontent.com/')
var tags = { purpose: 'azure-catalyst-lab', source: repoUrl }

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${prefix}-nsg'
  location: location
  tags: tags
  properties: { securityRules: [] }            // no inbound access; use Bastion
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${prefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.50.0.0/16'] }
    subnets: [
      { name: 'snet-host', properties: { addressPrefix: '10.50.1.0/24', networkSecurityGroup: { id: nsg.id } } }
      { name: 'snet-migrated', properties: { addressPrefix: '10.50.2.0/24' } }      // test-migrated VMs land here
      { name: 'AzureBastionSubnet', properties: { addressPrefix: '10.50.255.0/26' } }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${vmName}-pip'                        // outbound internet for downloads; no inbound rules allow traffic
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${vmName}-nic'
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: '${vnet.id}/subnets/snet-host' }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: false
        patchSettings: { patchMode: 'Manual' }  // no surprise reboots in the middle of replication
      }
    }
    storageProfile: {
      diskControllerType: 'NVMe'
      imageReference: { publisher: 'MicrosoftWindowsServer', offer: 'windowsserver2022', sku: '2022-datacenter-g2', version: 'latest' }
      osDisk: { createOption: 'FromImage', diskSizeGB: 128, managedDisk: { storageAccountType: 'Premium_LRS' } }
      dataDisks: [
        { lun: 0, createOption: 'Empty', diskSizeGB: dataDiskGB, caching: 'ReadOnly', managedDisk: { storageAccountType: 'Premium_LRS' } }
      ]
    }
    networkProfile: { networkInterfaces: [{ id: nic.id }] }
  }
}

// Installs Hyper-V + DHCP, downloads the repo and registers the build task, then reboots.
// The build (images, 16 nested VMs, AD, apps, appliance) continues after the reboot; see C:\Lab\status.json.
resource bootstrap 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'catalyst-lab-bootstrap'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: ['${rawBase}/${repoRef}/host/00-Bootstrap.ps1']
    }
    protectedSettings: {
      commandToExecute: 'powershell -NoProfile -ExecutionPolicy Bypass -File 00-Bootstrap.ps1 -RepoUrl ${repoUrl} -RepoRef ${repoRef} -AcceptSqlExpressLicense ${acceptSqlExpressLicense ? '1' : '0'}'
    }
  }
}

resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = if (bastionSku == 'Basic') {
  name: '${prefix}-bastion-pip'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-01-01' = {
  name: '${prefix}-bastion'
  location: location
  tags: tags
  sku: { name: bastionSku }
  properties: bastionSku == 'Developer' ? {
    virtualNetwork: { id: vnet.id }
  } : {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: '${vnet.id}/subnets/AzureBastionSubnet' }
          publicIPAddress: { id: bastionPip.id }
        }
      }
    ]
  }
}

output hostVmName string = vm.name
output bastionName string = bastion.name
output buildStatus string = 'The VM builds itself for ~100 minutes after deployment. Check progress: ./scripts/Get-LabStatus.ps1, or C:\\Lab\\status.json on the VM.'
