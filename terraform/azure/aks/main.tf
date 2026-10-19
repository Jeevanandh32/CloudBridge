# AKS: the cluster, its image registry, and the static public IP for the frontend LB.

# ==================== Setup ====================

terraform {
  required_version = ">= 1.10"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    # Only used to look up the account ID for the state bucket name
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    key = "azure/aks.tfstate"
  }
}

variable "project" {
  type    = string
  default = "cloudbridge"
}

variable "state_region" {
  description = "Region of the S3 state bucket"
  type        = string
  default     = "us-east-2"
}

# Subscription comes from ARM_SUBSCRIPTION_ID
provider "azurerm" {
  features {}
  # Providers were registered once by hand; see azure/network
  resource_provider_registrations = "none"
}

provider "aws" {
  region = var.state_region
}

locals {
  tags = { Project = var.project, ManagedBy = "terraform", Layer = "azure-aks" }
}

# ==================== Inputs from the network layer ====================

data "aws_caller_identity" "current" {}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
    key    = "azure/network.tfstate"
    region = var.state_region
  }
}

locals {
  network = data.terraform_remote_state.network.outputs
}

# ==================== AKS cluster ====================

variable "kubernetes_version" {
  description = "Same minor version as EKS, so manifests behave the same in both clouds"
  type        = string
  default     = "1.35"
}

variable "node_vm_size" {
  description = "2 vCPU / 4 GB, closest to t3.medium among sizes offered in northcentralus"
  type        = string
  default     = "Standard_B2als_v2"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "service_cidr" {
  type    = string
  default = "172.21.0.0/16"
}

variable "dns_service_ip" {
  description = "Must be inside service_cidr"
  type        = string
  default     = "172.21.0.10"
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "${var.project}-aks"
  location            = local.network.location
  resource_group_name = local.network.resource_group_name
  dns_prefix          = "${var.project}-aks"
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Free" # No control-plane SLA; fine for a lab, and $0

  default_node_pool {
    name       = "system"
    vm_size    = var.node_vm_size
    node_count = var.node_count

    # Azure CNI with a separate pod subnet: nodes and pods get VNet IPs from
    # different ranges, so pods are routable across the VPN like EKS pods
    vnet_subnet_id = local.network.subnet_ids["aks-nodes"]
    pod_subnet_id  = local.network.subnet_ids["aks-pods"]

    # Needed if vm_size ever changes (AKS swaps in a temporary pool)
    temporary_name_for_rotation = "systemtmp"

    # AKS's own defaults, declared so plans don't show drift. 10% of 2 nodes rounds up to
    # 1 surge node during upgrades: 4 + 2 = 6 vCPU, exactly the subscription's quota.
    upgrade_settings {
      max_surge                     = "10%"
      drain_timeout_in_minutes      = 0
      node_soak_duration_in_minutes = 0
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    service_cidr      = var.service_cidr
    dns_service_ip    = var.dns_service_ip
    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
  }

  tags = local.tags
}

# With a bring-your-own VNet, AKS needs rights on it to create load balancers
# and attach node NICs; the Azure CLI does this automatically, Terraform does not
resource "azurerm_role_assignment" "aks_network" {
  scope                = local.network.vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "node_resource_group" {
  description = "Where AKS puts node VMs and load balancers"
  value       = azurerm_kubernetes_cluster.aks.node_resource_group
}

output "kubeconfig_command" {
  value = "az aks get-credentials -g ${local.network.resource_group_name} -n ${azurerm_kubernetes_cluster.aks.name}"
}

# ==================== ACR image registry ====================

# In-region image registry: AKS never depends on AWS to pull images during a failover
data "azurerm_client_config" "current" {}

resource "azurerm_container_registry" "acr" {
  # Globally unique, letters/digits only: suffix from the subscription ID keeps it stable
  name                = "${var.project}${substr(replace(data.azurerm_client_config.current.subscription_id, "-", ""), 0, 8)}"
  location            = local.network.location
  resource_group_name = local.network.resource_group_name
  sku                 = "Basic" # Cheapest tier (~$0.17/day)
  admin_enabled       = false   # Nodes authenticate with their managed identity, not a password
  tags                = local.tags
}

# The kubelet identity is what nodes use to pull images
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

# ==================== Frontend public IP ====================

# Static public IP for the frontend's Standard LB: created here so its address is known
# to Terraform (Route 53 reads it) and survives app redeploys. The Service picks it up via
# the azure-pip-name annotation. This is the 3rd of the subscription's 3 public IPs.
resource "azurerm_public_ip" "frontend" {
  name                = "${var.project}-frontend-pip"
  location            = local.network.location
  resource_group_name = local.network.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

# AKS must be allowed to attach an IP that lives outside its own node resource group
resource "azurerm_role_assignment" "aks_frontend_pip" {
  scope                = azurerm_public_ip.frontend.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
}

output "frontend_public_ip" {
  value = azurerm_public_ip.frontend.ip_address
}

output "frontend_pip_name" {
  value = azurerm_public_ip.frontend.name
}
