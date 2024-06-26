terraform {
  # ---------------------------------------------------
  # Setup providers
  # ---------------------------------------------------
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.11.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 1.12.1"
    }
    grafana = {
      source  = "grafana/grafana"
      version = ">= 1.0.0"
    }
  }
}

provider "azurerm" {
  features {}
  environment = "public"
}
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.default.kube_config.0.host
  username               = azurerm_kubernetes_cluster.default.kube_config.0.username
  password               = azurerm_kubernetes_cluster.default.kube_config.0.password
  client_certificate     = base64decode(azurerm_kubernetes_cluster.default.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.default.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.default.kube_config.0.cluster_ca_certificate)
}
provider "kubectl" {
  host                   = azurerm_kubernetes_cluster.default.kube_config.0.host
  username               = azurerm_kubernetes_cluster.default.kube_config.0.username
  password               = azurerm_kubernetes_cluster.default.kube_config.0.password
  client_certificate     = base64decode(azurerm_kubernetes_cluster.default.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.default.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.default.kube_config.0.cluster_ca_certificate)
}
provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.default.kube_config.0.host
    username               = azurerm_kubernetes_cluster.default.kube_config.0.username
    password               = azurerm_kubernetes_cluster.default.kube_config.0.password
    client_certificate     = base64decode(azurerm_kubernetes_cluster.default.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.default.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.default.kube_config.0.cluster_ca_certificate)
  }
  # registry {
  #   url      = "oci://artifacts.private.registry"
  #   username = "api"
  #   password = var.artifactAPIToken
  # }
}
provider "grafana" {
  url  = azurerm_dashboard_grafana.default.endpoint
  auth = "securely pass api token"
}

## ---------------------------------------------------
# Initial resource group
## ---------------------------------------------------
# Utilize the current Azure CLI context as a data source for future reference
data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "default" {
  name     = "rg-test"
  location = "eastus2"
}

## ---------------------------------------------------
# user name and password setup for AKS node pools
## ---------------------------------------------------
resource "random_string" "userName" {
  length  = 8
  special = false
  upper   = false
}
resource "random_password" "userPasswd" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

## ---------------------------------------------------
# Azure KeyVault and components
## ---------------------------------------------------
resource "azurerm_key_vault" "default" {
  name                            = "kv-aks1234" # Must resolve to 24 characters or less
  resource_group_name             = azurerm_resource_group.default.name
  location                        = azurerm_resource_group.default.location
  tenant_id                       = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days      = 7
  enabled_for_deployment          = true
  enabled_for_template_deployment = true
  sku_name                        = "standard"
}
# Store the generated username/password in the KeyVault
resource "azurerm_key_vault_secret" "node_admin_name" {
  name         = "aksadminname"
  value        = random_string.userName.result
  key_vault_id = azurerm_key_vault.default.id
}

resource "azurerm_key_vault_secret" "node_admin_passwd" {
  name         = "aksadminpasswd"
  value        = random_password.userPasswd.result
  key_vault_id = azurerm_key_vault.default.id
}

resource "azurerm_kubernetes_cluster" "default" {
  name                = "aks-eastus2-test"
  resource_group_name = azurerm_resource_group.default.name
  location            = azurerm_resource_group.default.location
  dns_prefix          = azurerm_resource_group.default.name
  node_resource_group = "rg-aks-eastus2-test_node"

  # azure_active_directory_role_based_access_control {
  #   azure_rbac_enabled = false
  #   # admin_group_object_ids = var.adminGroupObjectIds
  # }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }
  network_profile {
    network_plugin = "azure"
    network_mode   = "transparent"
    network_policy = "calico"
  }

  default_node_pool {
    name       = "system"
    node_count = 1
    vm_size    = "Standard_B2ms"
    os_sku     = "Mariner"
  }

  windows_profile {
    admin_username = random_string.userName.result
    admin_password = random_password.userPasswd.result
  }

  identity {
    type = "SystemAssigned"
  }

  monitor_metrics {
    annotations_allowed = null
    labels_allowed      = null
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "default" {
  name                  = "win22"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.default.id
  mode                  = "User"
  enable_node_public_ip = false
  enable_auto_scaling   = true
  node_count            = 1
  min_count             = 1
  max_count             = 5
  max_pods              = 10
  vm_size               = "Standard_B2ms"
  os_type               = "Windows"
  os_sku                = "Windows2022"
}

resource "azurerm_role_assignment" "clusteradmin-rbacclusteradmin" {
  scope                = azurerm_kubernetes_cluster.default.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = "83cabf19-94f0-4d21-93d6-4a7959556a7b"
}

## ---------------------------------------------------
# Keyvault access policy for secrets providers
## ---------------------------------------------------
resource "azurerm_key_vault_access_policy" "akvp" {
  key_vault_id = azurerm_key_vault.default.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_kubernetes_cluster.default.key_vault_secrets_provider.0.secret_identity.0.object_id
  secret_permissions = [
    "Get"
  ]
}
resource "azurerm_key_vault_access_policy" "akv2k8s" {
  key_vault_id = azurerm_key_vault.default.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_kubernetes_cluster.default.kubelet_identity[0].object_id
  secret_permissions = [
    "Get"
  ]
}
