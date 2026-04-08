targetScope = 'subscription'

@description('Name of the resource group.')
param rgName string

@description('Azure region for all resources.')
param location string

@description('Name of the Network Security Group.')
param nsgName string

@description('Name of the Virtual Network.')
param vnetName string

@description('Name of the server subnet.')
param subnetName string

@description('Name of the VM resource (DNS server).')
param dnsVmName string

@description('Windows computer name for the DNS (max 15 characters).')
param dnsVmComputerName string

@description('Name of the file server VM resource.')
param fileServerVmName string

@description('Windows computer name for the file server (max 15 characters).')
param fileServerComputerName string

@description('Name of the dfsn server VM resource.')
param dfsnServerVmName string

@description('Windows computer name for the dfsn server (max 15 characters).')
param dfsnServerComputerName string

@description('Name of the client VM resource.')
param clientVmName string

@description('Windows computer name for the client (max 15 characters).')
param clientComputerName string

@description('Azure VM size SKU.')
param vmSize string

@description('VM admin username.')
param adminUser string

@secure()
@description('VM admin password.')
param adminPass string

@description('Globally unique storage account name (3-24 lowercase alphanumeric).')
param storageAccountName string

@description('Name of the Azure file share.')
param fileShareName string

@description('File share quota in GB.')
param shareQuota int = 100

@description('Availability zone (empty string for regional/no zone).')
param zone string = ''

@description('Name of the VPN Gateway resource.')
param gatewayName string = 'vpng-dfs-demo'

@description('Base64-encoded root certificate data for P2S VPN authentication.')
param clientRootCertData string

// var resourceToken = substring(toLower(uniqueString(subscription().subscriptionId, rgName)), 0, 5) 

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: rgName
  location: location
}

module network 'modules/network.bicep' = {
  name: 'network'
  scope: rg
  params: {
    location: location
    nsgName: nsgName
    vnetName: vnetName
    subnetName: subnetName
    dnsServerVmName: dnsVmName
    fileServerVmName: fileServerVmName
    clientVmName: clientVmName
    dfsnServerVmName: dfsnServerVmName
  }
}

module dnsVm 'modules/vm.bicep' = {
  name: 'dns-vm'
  scope: rg
  params: {
    location: location
    vmName: dnsVmName
    computerName: dnsVmComputerName
    vmSize: vmSize
    adminUser: adminUser
    adminPass: adminPass
    nicId: network.outputs.dnsNicId
    zone: zone
    vmPublisherName: 'MicrosoftWindowsServer'
    vmOffer: 'WindowsServer'
    vmSku: '2025-datacenter-azure-edition'
  }
}

module fileServerVm 'modules/vm.bicep' = {
  name: 'fileserver-vm'
  scope: rg
  params: {
    location: location
    vmName: fileServerVmName
    computerName: fileServerComputerName
    vmSize: vmSize
    adminUser: adminUser
    adminPass: adminPass
    nicId: network.outputs.fileServerNicId
    zone: zone
    vmPublisherName: 'MicrosoftWindowsServer'
    vmOffer: 'WindowsServer'
    vmSku: '2025-datacenter-azure-edition'
  }
}

module clientVm 'modules/vm.bicep' = {
  name: 'client-vm'
  scope: rg
  params: {
    location: location
    vmName: clientVmName
    computerName: clientComputerName
    vmSize: vmSize
    adminUser: adminUser
    adminPass: adminPass
    nicId: network.outputs.clientNicId
    zone: zone
    vmPublisherName: 'MicrosoftWindowsDesktop'
    vmOffer: 'windows-11'
    vmSku: 'win11-25h2-pro'
    licenseType: 'Windows_Client'
  }
}

module dfsnVm 'modules/vm.bicep' = {
  name: 'dfsn-vm'
  scope: rg
  params: {
    location: location
    vmName: dfsnServerVmName
    computerName: dfsnServerComputerName
    vmSize: vmSize
    adminUser: adminUser
    adminPass: adminPass
    nicId: network.outputs.dfsnNicId
    zone: zone
    vmPublisherName: 'MicrosoftWindowsServer'
    vmOffer: 'WindowsServer'
    vmSku: '2025-datacenter-azure-edition'
  }
}

module privateDns 'modules/private-dns.bicep' = {
  name: 'private-dns'
  scope: rg
  params: {
    vnetId: network.outputs.vnetId
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  scope: rg
  params: {
    location: location
    storageAccountName: storageAccountName
    fileShareName: fileShareName
    shareQuota: shareQuota
    privateEndpointSubnetId: network.outputs.peSubnetId
    privateDnsZoneId: privateDns.outputs.privateDnsZoneId
  }
}

module gateway 'modules/gateway.bicep' = {
  name: 'gateway'
  scope: rg
  params: {
    gatewayName: gatewayName
    virtualNetworkResourceId: network.outputs.vnetId
    clientRootCertData: clientRootCertData
  }
}

module dcStorageRole 'modules/role-assignment.bicep' = {
  name: 'dc-storage-role'
  scope: rg
  params: {
    principalId: dnsVm.outputs.vmPrincipalId
    storageAccountName: storage.outputs.storageAccountName
  }
}

module vmStorageRole 'modules/role-assignment.bicep' = {
  name: 'dfsnvm-storage-role'
  scope: rg
  params: {
    principalId: dfsnVm.outputs.vmPrincipalId
    storageAccountName: storage.outputs.storageAccountName
  }
}

module clientStorageRole 'modules/role-assignment.bicep' = {
  name: 'client-storage-role'
  scope: rg
  params: {
    principalId: clientVm.outputs.vmPrincipalId
    storageAccountName: storage.outputs.storageAccountName
  }
}

@description('Name of the deployed storage account.')
output storageAccountName string = storage.outputs.storageAccountName

@description('Resource ID of the storage account.')
output storageAccountId string = storage.outputs.storageAccountId

@description('Public IP of the VPN Gateway.')
output vpnGatewayPublicIp string = gateway.outputs.gatewayPublicIp

@description('Name of the VNet.')
output vnetName string = network.outputs.vnetNameOut
