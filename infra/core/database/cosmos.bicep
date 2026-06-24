targetScope = 'resourceGroup'

@description('The location used for all deployed resources')
param location string = resourceGroup().location

@description('Tags that will be applied to all resources')
param tags object = {}

@description('Cosmos DB account resource name')
param resourceName string

@description('Id of the user or app to assign application roles')
param principalId string

@description('Principal type of user or app')
param principalType string

@description('AI Services account name for the project parent')
param aiServicesAccountName string = ''

@description('AI project name for creating the connection')
param aiProjectName string = ''

@description('Name for the AI Foundry Cosmos DB connection')
param connectionName string

// Cosmos DB Account (serverless — no provisioned throughput, pay-per-request)
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: resourceName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
    enableAutomaticFailover: false
    enableMultipleWriteLocations: false
    disableKeyBasedMetadataWriteAccess: false
    publicNetworkAccess: 'Enabled'
    networkAclBypass: 'AzureServices'
    minimalTlsVersion: 'Tls12'
  }
}

// Agent thread storage database
resource agentDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  parent: cosmosAccount
  name: 'agent-threads'
  properties: {
    resource: {
      id: 'agent-threads'
    }
  }
}

// Threads container with session-based partition key
resource threadsContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = {
  parent: agentDatabase
  name: 'threads'
  properties: {
    resource: {
      id: 'threads'
      partitionKey: {
        paths: ['/sessionId']
        kind: 'Hash'
        version: 2
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        automatic: true
        includedPaths: [{ path: '/*' }]
        excludedPaths: [{ path: '/"_etag"/?' }]
      }
    }
  }
}

// Get reference to the AI project managed identity
resource aiAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = if (!empty(aiServicesAccountName) && !empty(aiProjectName)) {
  name: aiServicesAccountName
  resource aiProject 'projects' existing = {
    name: aiProjectName
  }
}

// Cosmos DB Built-in Data Contributor (data-plane RBAC) for the AI Project MI
// Role definition ID: 00000000-0000-0000-0000-000000000002
// name guid uses aiProject.id (calculable at start) rather than .identity.principalId
resource projectCosmosDataRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = if (!empty(aiServicesAccountName) && !empty(aiProjectName)) {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, aiAccount::aiProject.id, '00000000-0000-0000-0000-000000000002')
  properties: {
    roleDefinitionId: resourceId(
      'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions',
      cosmosAccount.name,
      '00000000-0000-0000-0000-000000000002'
    )
    principalId: aiAccount::aiProject.identity.principalId
    scope: cosmosAccount.id
  }
}

// Cosmos DB Built-in Data Contributor for the developer/deployer principal
resource userCosmosDataRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, principalId, '00000000-0000-0000-0000-000000000002')
  properties: {
    roleDefinitionId: resourceId(
      'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions',
      cosmosAccount.name,
      '00000000-0000-0000-0000-000000000002'
    )
    principalId: principalId
    scope: cosmosAccount.id
  }
}

// Cosmos DB Operator (control-plane RBAC) for the AI Project MI — required by
// the capability host bootstrap to create databases/containers under the account.
// Role definition ID: 230815da-be43-4aae-9cb4-875f7bd000aa
resource projectCosmosOperatorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(aiServicesAccountName) && !empty(aiProjectName)) {
  scope: cosmosAccount
  name: guid(cosmosAccount.id, aiAccount::aiProject.id, '230815da-be43-4aae-9cb4-875f7bd000aa')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '230815da-be43-4aae-9cb4-875f7bd000aa')
    principalId: aiAccount::aiProject.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Create the Foundry connection for Cosmos DB (used by capability host threadStorageConnections)
module cosmosConnection '../ai/connection.bicep' = if (!empty(aiServicesAccountName) && !empty(aiProjectName)) {
  name: 'cosmos-connection-creation'
  params: {
    aiServicesAccountName: aiServicesAccountName
    aiProjectName: aiProjectName
    connectionConfig: {
      name: connectionName
      category: 'CosmosDb'
      target: cosmosAccount.properties.documentEndpoint
      authType: 'AAD'
      isSharedToAll: true
      metadata: {
        ResourceId: cosmosAccount.id
        ApiType: 'Azure'
      }
    }
    credentials: {}
  }
}

output cosmosAccountName string = cosmosAccount.name
output cosmosAccountId string = cosmosAccount.id
output cosmosDocumentEndpoint string = cosmosAccount.properties.documentEndpoint
output cosmosConnectionName string = connectionName
