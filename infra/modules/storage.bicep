@description('Azure region for the storage account.')
param location string

@description('Globally unique storage account name (3-24 lowercase alphanumeric).')
param storageAccountName string

@description('Name of the Azure file share.')
param fileShareName string

@description('File share quota in GB.')
param shareQuota int = 100

@description('Resource ID of the subnet for the Private Endpoint.')
param privateEndpointSubnetId string

@description('Resource ID of the Private DNS Zone for file.core.windows.net.')
param privateDnsZoneId string

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-08-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    allowSharedKeyAccess: false
    // AD DS auth is configured post-deploy via join-storage-to-ad.ps1
    // Do not set directoryServiceOptions here — it conflicts with the script
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2025-08-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: false
    }
  }
}

resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-08-01' = {
  parent: fileService
  name: fileShareName
  properties: {
    shareQuota: shareQuota
    enabledProtocols: 'SMB'
  }
}

resource pe 'Microsoft.Network/privateEndpoints@2025-05-01' = {
  name: '${storageAccountName}-pe'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${storageAccountName}-pe-conn'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'file'
          ]
        }
      }
    ]
  }
}

resource peDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-05-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-file'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
