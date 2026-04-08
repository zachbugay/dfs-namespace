@description('Principal ID of the VM managed identity.')
param principalId string

@description('Name of the storage account to grant access to.')
param storageAccountName string

resource sa 'Microsoft.Storage/storageAccounts@2025-08-01' existing = {
  name: storageAccountName
}

// Contributor role on the storage account (control plane — manage keys, settings)
var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
resource contributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sa.id, principalId, contributorRoleId)
  scope: sa
  properties: {
    principalId: principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

// Storage File Data SMB Share Elevated Contributor (modify ACLs only)
var elevatedContributorRoleId = 'a7264617-510b-434b-a828-9731dc254ea7'
resource fileDataRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sa.id, principalId, elevatedContributorRoleId)
  scope: sa
  properties: {
    principalId: principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', elevatedContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

// Storage File Data Privileged Contributor (data plane — full file data access including superuser)
var privilegedContributorRoleId = '69566ab7-960f-475b-8e7c-b3118f30c6bd'
resource fileDataPrivilegedRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sa.id, principalId, privilegedContributorRoleId)
  scope: sa
  properties: {
    principalId: principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', privilegedContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}
