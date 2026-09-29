// Azure resources for the PROD (cloud) path of both applications: NetCore.API and Angular.web.
// Deploy once into an empty resource group (see .azure/SETUP.md, step 3):
//
//   az deployment group create -g rg-devops-exercise -f .azure/infra/main.bicep -p acrName=<unique>
//
// What the pipeline owns afterwards: container images, revisions, traffic weights and
// per-environment settings, all set by .azure/scripts/deploy-containerapps.sh. Re-running
// this template resets both apps to the placeholder image with 100% traffic on it, so after
// a re-run, re-run the PROD stage of each pipeline (or pass apiImage/webImage).

@description('Azure region for every resource.')
param location string = resourceGroup().location

@description('Globally unique Azure Container Registry name: 5-50 lowercase letters and digits.')
@minLength(5)
@maxLength(50)
param acrName string

@description('Container Apps environment name; also the prefix for the log workspace and identity.')
param environmentName string = 'cae-devops-exercise'

param apiAppName string = 'netcore-api'
param webAppName string = 'angular-web'

@description('Image the apps start with, before the pipeline deploys a real build. It must listen on 8080, like both real images.')
param apiImage string = 'mcr.microsoft.com/dotnet/samples:aspnetapp'
param webImage string = 'mcr.microsoft.com/dotnet/samples:aspnetapp'

@description('Scaling: at least one replica (no cold start), at most ten, scaling out at 50 concurrent requests per replica.')
param minReplicas int = 1
param maxReplicas int = 10
param concurrentRequestsPerReplica int = 50

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${environmentName}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// Basic tier: private, no admin user; pulls use a managed identity. Retention (keep the last N
// tags, purge untagged) is an ACR Task, see SETUP.md. The retention *policy* feature is Premium-only.
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
  }
}

// The apps pull from ACR as this identity: no registry passwords anywhere.
resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${environmentName}-acrpull'
  location: location
}

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, pullIdentity.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: pullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
    ]
  }
}

var apps = [
  { name: apiAppName, image: apiImage }
  { name: webAppName, image: webImage }
]

resource containerApps 'Microsoft.App/containerApps@2024-03-01' = [for app in apps: {
  name: app.name
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${pullIdentity.id}': {} }
  }
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      // Multiple active revisions are what make canary / blue-green traffic splitting possible.
      activeRevisionsMode: 'Multiple'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
        traffic: [
          { latestRevision: true, weight: 100 }
        ]
      }
      registries: [
        { server: acr.properties.loginServer, identity: pullIdentity.id }
      ]
    }
    template: {
      containers: [
        {
          name: app.name
          image: app.image
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http-concurrency'
            http: { metadata: { concurrentRequests: string(concurrentRequestsPerReplica) } }
          }
        ]
      }
    }
  }
  dependsOn: [ acrPull ]
}]

output acrLoginServer string = acr.properties.loginServer
output apiUrl string = 'https://${containerApps[0].properties.configuration.ingress.fqdn}'
output webUrl string = 'https://${containerApps[1].properties.configuration.ingress.fqdn}'
output pullIdentityPrincipalId string = pullIdentity.properties.principalId
