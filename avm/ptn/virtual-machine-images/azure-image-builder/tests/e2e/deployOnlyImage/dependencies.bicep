targetScope = 'subscription'

@description('Required. The name of the Resource Group.')
param resourceGroupName string

@description('Required. The name of the Resource Group to deploy the Image Template resources into.')
param imageTemplateResourceGroupName string

// User Assigned Identity (MSI) Parameters
@description('Required. The name of the Managed Identity used by deployment scripts.')
param deploymentScriptManagedIdentityName string

@description('Required. The name of the Managed Identity used by the Azure Image Builder.')
param imageManagedIdentityName string

// Azure Compute Gallery Parameters
@description('Required. The name of the Azure Compute Gallery.')
param computeGalleryName string

// Storage Account Parameters
@description('Required. The name of the storage account. Only needed if you want to upload scripts to be used during image baking.')
param assetsStorageAccountName string

@description('Required. The name of the storage account.')
param deploymentScriptStorageAccountName string

@description('Required. The name of the Deployment Script to the Storage Upload.')
param storageDeploymentScriptName string

// Virtual Network Parameters
@description('Required. The name of the Virtual Network.')
param virtualNetworkName string

// Shared Parameters
@description('Optional. The location to deploy into.')
param location string = deployment().location

var exampleScriptName = 'exampleScript.sh'
var addressPrefix = '10.0.0.0/16'
var subnetITName = 'subnet-it'
var subnetDSName = 'subnet-ds'

// The Image Definitions in the Azure Compute Gallery
var computeGalleryImageDefinitionsVar = [
  {
    hyperVGeneration: 'V2'
    name: 'sid-linux'
    osType: 'Linux'
    identifier: {
      publisher: 'devops'
      offer: 'devops_linux'
      sku: 'devops_linux_az'
    }
    osState: 'Generalized'
  }
]
var assetsStorageAccountContainerName = 'aibscripts'

// Role required for deployment script to be able to use a storage account via private networking
#disable-next-line use-recent-module-versions
resource storageFileDataPrivilegedContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '69566ab7-960f-475b-8e7c-b3118f30c6bd' // Storage File Data Priveleged Contributor
  scope: tenant()
}

// Resource Groups
#disable-next-line use-recent-module-versions
resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

// Always deployed as both an infra element & needed as a staging resource group for image building
#disable-next-line use-recent-module-versions
resource imageTemplateRg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: imageTemplateResourceGroupName
  location: location
}

// User Assigned Identity (MSI)
#disable-next-line use-recent-module-versions
module dsMsi 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.1' = {
  name: '${deployment().name}-ds-msi'
  scope: rg
  params: {
    name: deploymentScriptManagedIdentityName
    location: location
  }
}

#disable-next-line use-recent-module-versions
module imageMSI 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.1' = {
  name: '${deployment().name}-image-msi'
  scope: rg
  params: {
    name: imageManagedIdentityName
    location: location
  }
}

// MSI Subscription contributor assignment
#disable-next-line use-recent-module-versions
module imageMSI_build_rg_rbac 'br/public:avm/res/authorization/role-assignment/rg-scope:0.1.0' = {
  scope: imageTemplateRg
  name: '${deployment().name}-image-msi-rbac'
  params: {
    principalId: imageMSI.outputs.principalId
    roleDefinitionIdOrName: 'Contributor' // Required to build the image in the build-rg
    principalType: 'ServicePrincipal'
  }
}

// Azure Compute Gallery
#disable-next-line use-recent-module-versions
module azureComputeGallery 'br/public:avm/res/compute/gallery:0.9.2' = {
  name: '${deployment().name}-acg'
  scope: rg
  params: {
    name: computeGalleryName
    images: computeGalleryImageDefinitionsVar
    location: location
    roleAssignments: [
      {
        principalId: imageMSI.outputs.principalId
        roleDefinitionIdOrName: 'Contributor' // Required to publish images to the Azure Compute Gallery (ref: https://learn.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-permissions-cli#allow-vm-image-builder-to-distribute-images)
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

// Image Template Virtual Network
#disable-next-line use-recent-module-versions
module vnet 'br/public:avm/res/network/virtual-network:0.7.0' = {
  name: '${deployment().name}-vnet'
  scope: rg
  params: {
    name: virtualNetworkName
    addressPrefixes: [
      addressPrefix
    ]
    subnets: [
      {
        name: subnetITName
        addressPrefix: cidrSubnet(addressPrefix, 24, 0)
        privateLinkServiceNetworkPolicies: 'Disabled' // Required if using Azure Image Builder with existing VNET
        serviceEndpoints: [
          'Microsoft.Storage'
        ]
      }
      {
        name: subnetDSName
        addressPrefix: cidrSubnet(addressPrefix, 24, 1)
        privateLinkServiceNetworkPolicies: 'Disabled' // Required if using Azure Image Builder with existing VNET
        serviceEndpoints: [
          'Microsoft.Storage'
        ]
        delegation: 'Microsoft.ContainerInstance/containerGroups'
      }
    ]
    location: location
    roleAssignments: [
      {
        principalId: imageMSI.outputs.principalId
        roleDefinitionIdOrName: 'Network Contributor' // Required to use private networking (ref: https://learn.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-permissions-cli#permission-to-customize-images-on-your-virtual-networks)
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

// Assets Storage Account
#disable-next-line use-recent-module-versions
module assetsStorageAccount 'br/public:avm/res/storage/storage-account:0.25.0' = {
  name: '${deployment().name}-files-sa'
  scope: rg
  params: {
    name: assetsStorageAccountName
    allowSharedKeyAccess: false // Keys not needed if MSI is granted access
    location: location
    networkAcls: {
      defaultAction: 'Allow'
    }
    blobServices: {
      containers: [
        {
          name: assetsStorageAccountContainerName
          publicAccess: 'None'
          roleAssignments: [
            {
              // Allow Infra MSI to access storage account container to upload files - DO NOT REMOVE
              roleDefinitionIdOrName: 'Storage Blob Data Contributor'
              principalId: dsMsi.outputs.principalId
              principalType: 'ServicePrincipal'
            }
            {
              // Allow image MSI to access storage account container to read files - DO NOT REMOVE
              roleDefinitionIdOrName: 'Storage Blob Data Reader'
              principalId: imageMSI.outputs.principalId
              principalType: 'ServicePrincipal'
            }
          ]
        }
      ]
    }
  }
}

// Deployment scripts & their storage account
#disable-next-line use-recent-module-versions
module dsStorageAccount 'br/public:avm/res/storage/storage-account:0.25.0' = {
  name: '${deployment().name}-ds-sa'
  scope: rg
  params: {
    name: deploymentScriptStorageAccountName
    allowSharedKeyAccess: true // May not be disabled to allow deployment script to access storage account files
    roleAssignments: [
      {
        // Allow MSI to leverage the storage account for private networking of container instance
        // ref: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-script-bicep#access-private-virtual-network
        roleDefinitionIdOrName: storageFileDataPrivilegedContributorRole.id // Storage File Data Priveleged Contributor
        principalId: dsMsi.outputs.principalId
        principalType: 'ServicePrincipal'
      }
    ]
    location: location
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          // Allow deployment script to use storage account for private networking of container instance
          action: 'Allow'
          id: filter(vnet.outputs.subnetResourceIds, resourceId => last(split(resourceId, '/')) == subnetDSName)[0]
        }
      ]
    }
  }
}

// Upload storage account files
#disable-next-line use-recent-module-versions
module storageAccount_upload 'br/public:avm/res/resources/deployment-script:0.5.1' = {
  name: '${deployment().name}-storage-upload-ds'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: storageDeploymentScriptName
    kind: 'AzurePowerShell'
    azPowerShellVersion: '12.0'
    managedIdentities: {
      userAssignedResourceIds: [
        resourceId(
          subscription().subscriptionId,
          resourceGroupName,
          'Microsoft.ManagedIdentity/userAssignedIdentities',
          deploymentScriptManagedIdentityName
        )
      ]
    }
    scriptContent: loadTextContent('../../../../../../../utilities/e2e-template-assets/scripts/Set-StorageContainerContentByEnvVar.ps1')
    environmentVariables: [
      {
        name: '__SCRIPT__${replace(replace(exampleScriptName, '-', '__'), '.', '_') }' // May only be alphanumeric characters & underscores. The upload will replace '_' with '.' and '__' with '-'. E.g., Install__LinuxPowerShell_sh will be Install-LinuxPowerShell.sh
        value: loadTextContent('scripts/${exampleScriptName}')
      }
    ]

    arguments: ' -StorageAccountName "${assetsStorageAccountName}" -TargetContainer "${assetsStorageAccountContainerName}"'
    timeout: 'PT30M'
    cleanupPreference: 'Always'
    location: location
    storageAccountResourceId: dsStorageAccount.outputs.resourceId
    subnetResourceIds: [
      filter(vnet.outputs.subnetResourceIds, resourceId => last(split(resourceId, '/')) == subnetDSName)[0]
    ]
  }
}

@description('The image definitions used in the Azure Compute Gallery.')
output computeGalleryImageDefinitions array = computeGalleryImageDefinitionsVar

@description('The name of the created Resource Group.')
output resourceGroupName string = rg.name

@description('The name of the created Azure Compute Gallery')
output computeGalleryName string = azureComputeGallery.outputs.name

@description('The name of the created Virtual Network')
output virtualNetworkName string = vnet.outputs.name

@description('The name of the Storage Account Container hosting the customization files used by the Azure Image Builder.')
output assetsStorageAccountContainerName string = assetsStorageAccountContainerName

@description('The name of the create Storage Account hosting the customization files used by the Azure Image Builder.')
output assetsStorageAccountName string = assetsStorageAccount.outputs.name

@description('The name of the User-Assigned-Identity used by the Deployment Scripts.')
output deploymentScriptManagedIdentityName string = dsMsi.outputs.name

@description('The name of the Storage Account used by the Deployment Scripts.')
output deploymentScriptStorageAccountName string = dsStorageAccount.outputs.name

@description('The name of the subnet used by the Azure Image Builder.')
output imageSubnetName string = subnetITName
@description('The name of the subnet used by the Deployment Scripts.')
output deploymentScriptSubnetName string = subnetDSName

@description('The name of the User-Assigned-Identity used by the Azure Image Builder.')
output imageManagedIdentityName string = imageMSI.outputs.name

@description('The name of the Resource Group used by the Azure Image Builder.')
output imageTemplateResourceGroupName string = imageTemplateRg.name

@description('The name of the script uploaded to the Assets Storage Account to use in the Azure Image Builder customization steps.')
output exampleScriptName string = exampleScriptName
