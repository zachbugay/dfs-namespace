@description('Name for the VPN Gateway resource.')
param gatewayName string

@description('Resource ID of the Virtual Network.')
param virtualNetworkResourceId string

@description('Base64-encoded root certificate public data for P2S client auth.')
param clientRootCertData string

module vnetGateway 'br/public:avm/res/network/virtual-network-gateway:0.10.1' = {
  name: 'vnet-gateway-avm-deployment'
  params: {
    name: gatewayName
    clusterSettings: {
      clusterMode: 'activePassiveNoBgp'
    }
    gatewayType: 'Vpn'
    enableBgpRouteTranslationForNat: false
    skuName: 'VpnGw1AZ'
    virtualNetworkResourceId: virtualNetworkResourceId
    allowRemoteVnetTraffic: true
    allowVirtualWanTraffic: false
    clientRootCertData: clientRootCertData
    vpnType: 'RouteBased'
    vpnClientAddressPoolPrefix: '172.16.0.0/24'
    vpnGatewayGeneration: 'Generation2'
  }
}

@description('Public IP address of the VPN Gateway.')
output gatewayPublicIp string = vnetGateway.outputs.?primaryPublicIpAddress ?? ''

@description('Resource ID of the VPN Gateway.')
output gatewayResourceId string = vnetGateway.outputs.resourceId
