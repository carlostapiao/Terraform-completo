terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = "e690edad-0257-4dec-b4c9-08e163433edb"
}

variable "location" {
  default = "centralus"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-enterprise-final"
  location = var.location
}

# KEY VAULT
resource "azurerm_key_vault" "kv" {
  name                = "kv-enterprise-aks"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault_secret" "sql_password" {
  name         = "sql-password"
  value        = "P@ssw0rd1234!"
  key_vault_id = azurerm_key_vault.kv.id
}

# ACR
resource "azurerm_container_registry" "acr" {
  name                = "carlos69lamejor"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = true
}

# AKS
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-enterprise-final"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "aksenterprise"

  default_node_pool {
    name       = "system"
    node_count = 1
    vm_size    = "Standard_B2ps_v2"
  }

  identity {
    type = "SystemAssigned"
  }

  role_based_access_control_enabled = true

  network_profile {
    network_plugin    = "azure"
    load_balancer_sku = "standard"
  }

  private_cluster_enabled = false
}

# ACR pull
resource "azurerm_role_assignment" "acr_pull" {
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name = "AcrPull"
  scope                = azurerm_container_registry.acr.id
}

# SQL
resource "azurerm_mssql_server" "sql" {
  name                         = "sql-enterprise-final"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = var.location
  administrator_login          = "sqladmin"
  administrator_login_password = azurerm_key_vault_secret.sql_password.value
  version                      = "12.0"
}

resource "azurerm_mssql_database" "db" {
  name      = "db-enterprise"
  server_id = azurerm_mssql_server.sql.id
  sku_name  = "S0"
}

# APIM
resource "azurerm_api_management" "apim" {
  name                = "apim-enterprise-final"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  publisher_name      = "Carlos"
  publisher_email     = "test@test.com"
  sku_name            = "Consumption_0"
}

# Kubernetes provider (para leer ingress)
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.aks.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate)
}

# Leer ingress
data "kubernetes_service" "ingress" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }
}

# APIM API conectada al ingress
resource "azurerm_api_management_api" "api" {
  name                = "aks-api"
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name
  revision            = "1"
  display_name        = "AKS API"
  path                = "apps"
  protocols           = ["http"]

  service_url = "http://${data.kubernetes_service.ingress.status[0].load_balancer[0].ingress[0].ip}"
}