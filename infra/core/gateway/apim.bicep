targetScope = 'resourceGroup'

@description('Location for all resources')
param location string = resourceGroup().location

@description('Tags to apply to all resources')
param tags object = {}

@description('APIM service name')
param resourceName string

@description('Publisher email for the API Management service')
param publisherEmail string

@description('Publisher name for the API Management service')
param publisherName string

@description('SKU of the API Management service. Developer = full features, ~45 min provision; Consumption = serverless, instant.')
@allowed(['Developer', 'Consumption', 'Basic', 'Standard', 'Premium'])
param skuName string = 'Developer'

@description('SKU capacity units. Must be 0 for Consumption SKU.')
param skuCapacity int = 1

// API Management service
resource apimService 'Microsoft.ApiManagement/service@2022-08-01' = {
  name: resourceName
  location: location
  tags: tags
  sku: {
    name: skuName
    capacity: skuName == 'Consumption' ? 0 : skuCapacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'None'
    publicNetworkAccess: 'Enabled'
  }
}

// AI Gateway product — groups all AI backend APIs
resource aiGatewayProduct 'Microsoft.ApiManagement/service/products@2022-08-01' = {
  parent: apimService
  name: 'ai-gateway'
  properties: {
    displayName: 'AI Gateway'
    description: 'Product for Azure AI Foundry / OpenAI API proxying with rate limiting and observability'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

// Global policy: retry on 429, add correlation id header, forward to backend
resource apimGlobalPolicy 'Microsoft.ApiManagement/service/policies@2022-08-01' = {
  parent: apimService
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '''
<policies>
  <inbound>
    <base />
    <set-header name="x-correlation-id" exists-action="skip">
      <value>@(context.RequestId.ToString())</value>
    </set-header>
  </inbound>
  <backend>
    <retry condition="@(context.Response.StatusCode == 429)" count="3" interval="10" max-interval="60" delta="5" first-fast-retry="false">
      <forward-request />
    </retry>
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
'''
  }
}

output apimServiceName string = apimService.name
output apimServiceId string = apimService.id
output apimGatewayUrl string = apimService.properties.gatewayUrl
output apimManagementApiUrl string = apimService.properties.managementApiUrl
output apimPrincipalId string = apimService.identity.principalId
