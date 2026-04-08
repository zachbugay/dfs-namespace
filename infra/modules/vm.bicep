@description('Azure region for the VM.')
param location string

@description('Name of the VM resource.')
param vmName string

@description('Windows computer name (max 15 characters).')
param computerName string

@description('Azure VM size SKU.')
param vmSize string

@description('VM admin username.')
param adminUser string

@secure()
@description('VM admin password.')
param adminPass string

@description('Resource ID of the NIC to attach.')
param nicId string

@description('Availability zone (empty string for regional/no zone).')
param zone string = ''

@description('OS disk size in GB.')
param osDiskSizeGB int = 128

@description('Publisher name')
param vmPublisherName string

@description('VM Offer')
param vmOffer string

@description('VM SKU')
param vmSku string

@description('VM Version')
param vmVersion string = 'latest'

@description('License type (e.g. Windows_Client for desktop SKUs, Windows_Server for server SKUs). Empty string omits the property.')
param licenseType string = ''

resource vm 'Microsoft.Compute/virtualMachines@2025-04-01' = {
  name: vmName
  location: location
  zones: empty(zone) ? [] : [zone]
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    licenseType: empty(licenseType) ? null : licenseType
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: computerName
      adminUsername: adminUser
      adminPassword: adminPass
    }
    storageProfile: {
      imageReference: {
        publisher: vmPublisherName
        offer: vmOffer
        sku: vmSku
        version: vmVersion
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: osDiskSizeGB
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nicId
        }
      ]
    }
  }
}

output vmId string = vm.id
output vmPrincipalId string = vm.identity.principalId
