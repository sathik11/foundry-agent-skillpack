targetScope = 'subscription'
// targetScope = 'resourceGroup'

@minLength(1)
@maxLength(64)
@description('Name of the environment that can be used as part of naming resource convention')
param environmentName string

@minLength(1)
@maxLength(90)
@description('Name of the resource group to use or create')
param resourceGroupName string = 'rg-${environmentName}'

// Restricted locations to match list from
// https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/responses?tabs=python-key#region-availability
@minLength(1)
@description('Primary location for all resources')
@allowed([
  'australiaeast'
  'brazilsouth'
  'canadacentral'
  'canadaeast'
  'eastus'
  'eastus2'
  'francecentral'
  'germanywestcentral'
  'italynorth'
  'japaneast'
  'koreacentral'
  'northcentralus'
  'norwayeast'
  'polandcentral'
  'southafricanorth'
  'southcentralus'
  'southeastasia'
  'southindia'
  'spaincentral'
  'swedencentral'
  'switzerlandnorth'
  'uaenorth'
  'uksouth'
  'westus'
  'westus2'
  'westus3'
])
param location string

param aiDeploymentsLocation string = location

@description('Id of the user or app to assign application roles')
param principalId string

@description('Principal type of user or app')
param principalType string

@description('Optional salt to diversify resource names across project recreations')
param resourceTokenSalt string = ''

@description('Optional. Name of an existing AI Services account within the resource group. If not provided, a new one will be created.')
param aiFoundryResourceName string = ''

@description('Optional. Name of the AI Foundry project. If not provided, a default name will be used.')
param aiFoundryProjectName string = 'ai-project-${environmentName}'

@description('List of model deployments')
param aiProjectDeploymentsJson string = '[]'

@description('List of connections')
param aiProjectConnectionsJson string = '[]'

@secure()
@description('JSON map of connection name to credentials object. Example: {"my-conn":{"key":"secret"}}')
param aiProjectConnectionCredentialsJson string = '{}'

@description('List of resources to create and connect to the AI project')
param aiProjectDependentResourcesJson string = '[]'

var aiProjectDeployments = json(aiProjectDeploymentsJson)
var aiProjectConnections = json(aiProjectConnectionsJson)
var aiProjectConnectionCreds = json(aiProjectConnectionCredentialsJson)
var aiProjectDependentResources = json(aiProjectDependentResourcesJson)

@description('Enable hosted agent deployment')
param enableHostedAgents bool

@description('Enable the capability host for supporting BYO storage of agent conversations. When false and hosted agents are enabled, the capability host is not created.')
param enableCapabilityHost bool

@description('Enable monitoring for the AI project')
param enableMonitoring bool

@description('When true, skip Foundry project/role/connection provisioning and reference the existing project read-only. Use when pointing at an existing Foundry project via --project-id.')
param useExistingAiProject bool = false

@description('Optional. Existing container registry resource ID. If provided, no new ACR will be created and a connection to this ACR will be established.')
param existingContainerRegistryResourceId string = ''

@description('Optional. Existing container registry endpoint (login server). Required if existingContainerRegistryResourceId is provided.')
param existingContainerRegistryEndpoint string = ''

@description('Optional. Name of an existing ACR connection on the Foundry project. If provided, no new ACR or connection will be created.')
param existingAcrConnectionName string = ''

@description('Optional. Skip ACR creation entirely (e.g. for code-deploy scenarios where no container registry is needed). Defaults to false for backward compatibility.')
param skipAcr bool = false

@description('Optional. Existing Application Insights connection string. If provided, a connection will be created but no new App Insights resource.')
param existingApplicationInsightsConnectionString string = ''

@description('Optional. Existing Application Insights resource ID. Used for connection metadata when providing an existing App Insights.')
param existingApplicationInsightsResourceId string = ''

@description('Optional. Name of an existing Application Insights connection on the Foundry project. If provided, no new App Insights or connection will be created.')
param existingAppInsightsConnectionName string = ''

@description('Optional. Cosmos DB connection name override for the capability host. When empty and enableCapabilityHost=true, a new Cosmos DB account is provisioned automatically.')
param cosmosConnectionNameOverride string = ''

@description('Provision a Cosmos DB account in the resource group.')
param enableCosmos bool = true

@description('Provision an Azure Storage account in the resource group.')
param enableStorage bool = true

@description('Provision an Azure AI Search service in the resource group.')
param enableSearch bool = true

// ── APIM (optional AI Gateway) ─────────────────────────────────────────────
@description('When true, deploy an Azure API Management service as an AI Gateway in front of the Foundry/OpenAI endpoints. Note: Developer SKU takes ~45 min to provision.')
param enableApim bool = false

@description('Publisher email for the APIM service. Required when enableApim=true.')
param apimPublisherEmail string = 'admin@example.com'

@description('Publisher name for the APIM service. Required when enableApim=true.')
param apimPublisherName string = 'AI Foundry Admin'

@description('APIM SKU. Developer = full features + ~45 min provision. Consumption = serverless + instant provision.')
@allowed(['Developer', 'Consumption', 'Basic', 'Standard', 'Premium'])
param apimSkuName string = 'Developer'

@description('Creation date stamp (ddMMyyyy) applied as a tag to EVERY resource. Defaults to deploy time. Intentionally a TAG, not part of resource names — a date in the name would break idempotent re-provisioning (it would create new resources and orphan the old ones).')
param createdOn string = utcNow('ddMMyyyy')

@description('Purpose tag for human-friendly discovery: az resource list --tag purpose=<value>.')
param baselinePurpose string = 'skillpack-e2e-baseline'

// Tags that should be applied to all resources.
// 
// Note that 'azd-service-name' tags should be applied separately to service host resources.
// Example usage:
//   tags: union(tags, { 'azd-service-name': <service name in azure.yaml> })
var tags = {
  'azd-env-name': environmentName
  createdOn: createdOn
  purpose: baselinePurpose
  managedBy: 'infra/baseline.sh'
}

// Check if resource group exists and create it if it doesn't
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// Build dependent resources array conditionally
// Check if ACR already exists in the user-provided array to avoid duplicates
// Also skip if user provided an existing container registry endpoint or connection name
var hasAcr = contains(map(aiProjectDependentResources, r => r.resource), 'registry')
var shouldCreateAcr = !skipAcr && enableHostedAgents && !hasAcr && empty(existingContainerRegistryResourceId) && empty(existingAcrConnectionName)
var dependentResources = shouldCreateAcr ? union(aiProjectDependentResources, [
  {
    resource: 'registry'
    connectionName: 'acr-${uniqueString(subscription().id, resourceGroupName, location)}'
  }
]) : aiProjectDependentResources

// AI Project module — only when creating new resources
module aiProject 'core/ai/ai-project.bicep' = if (!useExistingAiProject) {
  scope: rg
  name: 'ai-project'
  params: {
    tags: tags
    location: aiDeploymentsLocation
    aiFoundryProjectName: aiFoundryProjectName
    principalId: principalId
    principalType: principalType
    existingAiAccountName: aiFoundryResourceName
    deployments: aiProjectDeployments
    connections: aiProjectConnections
    connectionCredentials: aiProjectConnectionCreds
    additionalDependentResources: dependentResources
    enableMonitoring: enableMonitoring
    enableHostedAgents: enableHostedAgents
    enableCapabilityHost: enableCapabilityHost
    existingContainerRegistryResourceId: existingContainerRegistryResourceId
    existingContainerRegistryEndpoint: existingContainerRegistryEndpoint
    existingAcrConnectionName: existingAcrConnectionName
    existingApplicationInsightsConnectionString: existingApplicationInsightsConnectionString
    existingApplicationInsightsResourceId: existingApplicationInsightsResourceId
    existingAppInsightsConnectionName: existingAppInsightsConnectionName
    cosmosConnectionNameOverride: cosmosConnectionNameOverride
    enableCosmos: enableCosmos
    enableStorage: enableStorage
    enableSearch: enableSearch
    resourceTokenSalt: resourceTokenSalt
  }
}

// Existing project module — read-only reference when reusing an existing Foundry project
module existingAiProject 'core/ai/existing-ai-project.bicep' = if (useExistingAiProject) {
  scope: rg
  name: 'existing-ai-project'
  params: {
    aiServicesAccountName: aiFoundryResourceName
    aiFoundryProjectName: aiFoundryProjectName
    deployments: aiProjectDeployments
    existingAcrConnectionName: existingAcrConnectionName
    existingContainerRegistryEndpoint: existingContainerRegistryEndpoint
    existingApplicationInsightsConnectionString: existingApplicationInsightsConnectionString
    existingApplicationInsightsResourceId: existingApplicationInsightsResourceId
    connections: aiProjectConnections
    connectionCredentials: aiProjectConnectionCreds
  }
}

// ACR for existing project — create when hosted agents need a registry but the existing project has none
var shouldCreateAcrForExistingProject = useExistingAiProject && shouldCreateAcr
var acrConnectionName = 'acr-${uniqueString(subscription().id, resourceGroupName, location)}'

module acrForExistingProject 'core/host/acr.bicep' = if (shouldCreateAcrForExistingProject) {
  scope: rg
  name: 'acr-for-existing-project'
  params: {
    location: location
    tags: tags
    resourceName: 'cr${uniqueString(subscription().id, resourceGroupName, location)}'
    connectionName: acrConnectionName
    principalId: principalId
    principalType: principalType
    aiServicesAccountName: aiFoundryResourceName
    aiProjectName: aiFoundryProjectName
  }
}

// ── APIM AI Gateway (optional) ─────────────────────────────────────────────
module apim 'core/gateway/apim.bicep' = if (enableApim) {
  scope: rg
  name: 'apim'
  params: {
    location: location
    tags: tags
    resourceName: 'apim-${uniqueString(subscription().id, resourceGroupName, location)}'
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    skuName: apimSkuName
  }
}

// Resources
output AZURE_RESOURCE_GROUP string = resourceGroupName
output AZURE_AI_ACCOUNT_ID string = useExistingAiProject ? existingAiProject.outputs.accountId : aiProject.outputs.accountId
output AZURE_AI_PROJECT_ID string = useExistingAiProject ? existingAiProject.outputs.projectId : aiProject.outputs.projectId
output AZURE_AI_FOUNDRY_PROJECT_ID string = useExistingAiProject ? existingAiProject.outputs.projectId : aiProject.outputs.projectId
output AZURE_AI_ACCOUNT_NAME string = useExistingAiProject ? existingAiProject.outputs.aiServicesAccountName : aiProject.outputs.aiServicesAccountName
output AZURE_AI_PROJECT_NAME string = useExistingAiProject ? existingAiProject.outputs.projectName : aiProject.outputs.projectName

// Endpoints
output AZURE_AI_PROJECT_ENDPOINT string = useExistingAiProject ? existingAiProject.outputs.AZURE_AI_PROJECT_ENDPOINT : aiProject.outputs.AZURE_AI_PROJECT_ENDPOINT
output FOUNDRY_PROJECT_ENDPOINT string = useExistingAiProject ? existingAiProject.outputs.FOUNDRY_PROJECT_ENDPOINT : aiProject.outputs.FOUNDRY_PROJECT_ENDPOINT
output AZURE_OPENAI_ENDPOINT string = useExistingAiProject ? existingAiProject.outputs.AZURE_OPENAI_ENDPOINT : aiProject.outputs.AZURE_OPENAI_ENDPOINT
output APPLICATIONINSIGHTS_CONNECTION_STRING string = useExistingAiProject ? existingAiProject.outputs.APPLICATIONINSIGHTS_CONNECTION_STRING : aiProject.outputs.APPLICATIONINSIGHTS_CONNECTION_STRING
output APPLICATIONINSIGHTS_RESOURCE_ID string = useExistingAiProject ? existingAiProject.outputs.APPLICATIONINSIGHTS_RESOURCE_ID : aiProject.outputs.APPLICATIONINSIGHTS_RESOURCE_ID

// Dependent Resources and Connections

// ACR
output AZURE_AI_PROJECT_ACR_CONNECTION_NAME string = shouldCreateAcrForExistingProject ? acrForExistingProject.outputs.containerRegistryConnectionName : (useExistingAiProject ? existingAiProject.outputs.dependentResources.registry.connectionName : aiProject.outputs.dependentResources.registry.connectionName)
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = shouldCreateAcrForExistingProject ? acrForExistingProject.outputs.containerRegistryLoginServer : (useExistingAiProject ? existingAiProject.outputs.dependentResources.registry.loginServer : aiProject.outputs.dependentResources.registry.loginServer)

// Bing Search
output BING_GROUNDING_CONNECTION_NAME  string = useExistingAiProject ? existingAiProject.outputs.dependentResources.bing_grounding.connectionName : aiProject.outputs.dependentResources.bing_grounding.connectionName
output BING_GROUNDING_RESOURCE_NAME string = useExistingAiProject ? existingAiProject.outputs.dependentResources.bing_grounding.name : aiProject.outputs.dependentResources.bing_grounding.name
output BING_GROUNDING_CONNECTION_ID string = useExistingAiProject ? existingAiProject.outputs.dependentResources.bing_grounding.connectionId : aiProject.outputs.dependentResources.bing_grounding.connectionId

// Bing Custom Search
output BING_CUSTOM_GROUNDING_CONNECTION_NAME string = useExistingAiProject ? existingAiProject.outputs.dependentResources.bing_custom_grounding.connectionName : aiProject.outputs.dependentResources.bing_custom_grounding.connectionName
output BING_CUSTOM_GROUNDING_NAME string = useExistingAiProject ? existingAiProject.outputs.dependentResources.bing_custom_grounding.name : aiProject.outputs.dependentResources.bing_custom_grounding.name
output BING_CUSTOM_GROUNDING_CONNECTION_ID string = useExistingAiProject ? existingAiProject.outputs.dependentResources.bing_custom_grounding.connectionId : aiProject.outputs.dependentResources.bing_custom_grounding.connectionId

// Azure AI Search
output AZURE_AI_SEARCH_CONNECTION_NAME string = useExistingAiProject ? existingAiProject.outputs.dependentResources.search.connectionName : aiProject.outputs.dependentResources.search.connectionName
output AZURE_AI_SEARCH_SERVICE_NAME string = useExistingAiProject ? existingAiProject.outputs.dependentResources.search.serviceName : aiProject.outputs.dependentResources.search.serviceName

// Azure Storage
output AZURE_STORAGE_CONNECTION_NAME string = useExistingAiProject ? existingAiProject.outputs.dependentResources.storage.connectionName : aiProject.outputs.dependentResources.storage.connectionName
output AZURE_STORAGE_ACCOUNT_NAME string = useExistingAiProject ? existingAiProject.outputs.dependentResources.storage.accountName : aiProject.outputs.dependentResources.storage.accountName

// Connections
output AI_PROJECT_CONNECTION_IDS_JSON string = useExistingAiProject ? string(existingAiProject.outputs.connectionIds) : string(aiProject.outputs.connectionIds)

// Cosmos DB (capability host thread storage)
output AZURE_COSMOS_ACCOUNT_NAME string = (!useExistingAiProject) ? aiProject.outputs.dependentResources.cosmos.accountName : ''
output AZURE_COSMOS_CONNECTION_NAME string = (!useExistingAiProject) ? aiProject.outputs.dependentResources.cosmos.connectionName : ''
output AZURE_COSMOS_ENDPOINT string = (!useExistingAiProject) ? aiProject.outputs.dependentResources.cosmos.endpoint : ''

// Capability host vector-store search + blob storage connection names
output CAPABILITY_HOST_SEARCH_CONNECTION_NAME string = (!useExistingAiProject) ? aiProject.outputs.dependentResources.capHostSearch.connectionName : ''
output CAPABILITY_HOST_STORAGE_CONNECTION_NAME string = (!useExistingAiProject) ? aiProject.outputs.dependentResources.capHostStorage.connectionName : ''

// APIM AI Gateway
output APIM_GATEWAY_URL string = enableApim ? apim.outputs.apimGatewayUrl : ''
output APIM_SERVICE_NAME string = enableApim ? apim.outputs.apimServiceName : ''
