@description('Azure region for all networking resources.')
param location string

@description('Name of the Network Security Group.')
param nsgName string

@description('Name of the Virtual Network.')
param vnetName string

@description('Name of the server subnet.')
param subnetName string

@description('Name of the DNS VM (used to derive NIC name).')
param dnsServerVmName string

@description('Name of the file server VM (used to derive NIC name).')
param fileServerVmName string

@description('Name of the client VM (used to derive NIC name).')
param clientVmName string

@description('Name of the DFS-N VM (used to derive NIC name).')
param dfsnServerVmName string

@description('Static private IP for the DC VM.')
param dnsVmStaticPrivateIp string = '10.0.1.4'

@description('Static private IP for the file server VM.')
param fileServerStaticPrivateIp string = '10.0.1.5'

@description('Static private IP for the client VM.')
param clientStaticPrivateIp string = '10.0.1.6'

@description('Static private IP for the client VM.')
param dfsnStaticPrivateIp string = '10.0.1.7'

var dnsServerNicName = '${dnsServerVmName}-nic'
var fileServerNicName = '${fileServerVmName}-nic'
var clientNicName = '${clientVmName}-nic'
var dfsnNicName = '${dfsnServerVmName}-nic'

resource nsg 'Microsoft.Network/networkSecurityGroups@2025-05-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSMBInbound'
        properties: {
          priority: 1010
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '445'
          description: 'SMB inbound within VNet'
        }
      }
      {
        name: 'AllowRDPFromVPN'
        properties: {
          priority: 1020
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '172.16.0.0/24'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '3389'
          description: 'RDP from P2S VPN clients'
        }
      }
      {
        name: 'AllowDNSInbound'
        properties: {
          priority: 1030
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '53'
          description: 'DNS (TCP+UDP) to AD DNS server'
        }
      }
      {
        name: 'AllowKerberosInbound'
        properties: {
          priority: 1040
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '88'
          description: 'Kerberos auth to DC'
        }
      }
      {
        name: 'AllowRPCEndpointMapper'
        properties: {
          priority: 1050
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '135'
          description: 'RPC Endpoint Mapper for DFS referrals and AD RPC'
        }
      }
      {
        name: 'AllowNetBIOSInbound'
        properties: {
          priority: 1060
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '137-139'
          description: 'NetBIOS name service, datagram, and session (TCP+UDP)'
        }
      }
      {
        name: 'AllowLdapInbound-389'
        properties: {
          priority: 1070
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '389'
          description: 'LDAP TCP/UDP'
        }
      }
      {
        name: 'AllowLdapInbound-636'
        properties: {
          priority: 1080
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '636'
          description: 'LDAP TCP/UDP'
        }
      }
      {
        name: 'AllowGlobalCatalogbound-3268'
        properties: {
          priority: 1090
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '3268'
          description: 'LDAP TCP/UDP'
        }
      }
      {
        name: 'AllowRpcDynamicPorts-49152-65535'
        properties: {
          priority: 1100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '49152-65535'
          description: 'RPC Dynamic Ports TCP/UDP'
        }
      }
      {
        name: 'AllowSMBOutbound'
        properties: {
          priority: 1110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '445'
          description: 'SMB outbound to Azure Files PE'
        }
      }
    ]
  }
}

// DNS is initially Azure DNS; deploy.ps1 updates it to the VM IP after AD setup.
resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: '10.0.2.0/24'
        }
      }
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: '10.0.255.0/27'
        }
      }
    ]
  }
}

resource serverSubnet 'Microsoft.Network/virtualNetworks/subnets@2025-05-01' existing = {
  parent: vnet
  name: subnetName
}

resource nic 'Microsoft.Network/networkInterfaces@2025-05-01' = {
  name: dnsServerNicName
  location: location
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: serverSubnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: dnsVmStaticPrivateIp
        }
      }
    ]
  }
}

resource fileServerNic 'Microsoft.Network/networkInterfaces@2025-05-01' = {
  name: fileServerNicName
  location: location
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: serverSubnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: fileServerStaticPrivateIp
        }
      }
    ]
  }
}

resource clientNic 'Microsoft.Network/networkInterfaces@2025-05-01' = {
  name: clientNicName
  location: location
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: serverSubnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: clientStaticPrivateIp
        }
      }
    ]
  }
}

resource dfsnNic 'Microsoft.Network/networkInterfaces@2025-05-01' = {
  name: dfsnNicName
  location: location
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: serverSubnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: dfsnStaticPrivateIp
        }
      }
    ]
  }
}

@description('Resource ID of the DNS NIC.')
output dnsNicId string = nic.id

@description('Resource ID of the file server NIC.')
output fileServerNicId string = fileServerNic.id

@description('Resource ID of the client NIC.')
output clientNicId string = clientNic.id

@description('Resource ID of the client NIC.')
output dfsnNicId string = dfsnNic.id

@description('Resource ID of the VNet.')
output vnetId string = vnet.id

@description('Name of the VNet.')
output vnetNameOut string = vnet.name

@description('Resource ID of the Private Endpoint subnet.')
output peSubnetId string = vnet.properties.subnets[1].id
