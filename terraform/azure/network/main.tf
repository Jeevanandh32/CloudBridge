# Azure network: resource group, VNet, subnets, and the VPN gateway for the AWS tunnels.

# ==================== Setup ====================

terraform {
  required_version = ">= 1.10"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  # State lives in the same S3 bucket as the AWS layers
  backend "s3" {
    key = "azure/network.tfstate"
  }
}

# Subscription comes from ARM_SUBSCRIPTION_ID
provider "azurerm" {
  features {}
  # Needed providers (Network, Compute, ContainerService, ...) were registered once by hand;
  # skipping auto-registration keeps plans fast on the student subscription
  resource_provider_registrations = "none"
}

variable "project" {
  type    = string
  default = "cloudbridge"
}

locals {
  tags = { Project = var.project, ManagedBy = "terraform", Layer = "azure-network" }
}

# ==================== Resource group ====================

variable "location" {
  description = "Student subscription policy allows only a few regions; northcentralus is closest to AWS us-east-2"
  type        = string
  default     = "northcentralus"
}

resource "azurerm_resource_group" "rg" {
  name     = "${var.project}-rg"
  location = var.location
  tags     = local.tags
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "location" {
  value = azurerm_resource_group.rg.location
}

# ==================== VNet ====================

variable "vnet_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.project}-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags
}

output "vnet_id" {
  value = azurerm_virtual_network.vnet.id
}

output "vnet_cidr" {
  value = var.vnet_cidr
}

# ==================== Subnets ====================

variable "subnets" {
  type = map(string)
  default = {
    aks-nodes     = "10.20.0.0/22"
    aks-pods      = "10.20.32.0/19"
    test          = "10.20.64.0/24"
    GatewaySubnet = "10.20.255.0/27"
  }
}

resource "azurerm_subnet" "this" {
  for_each             = var.subnets
  name                 = each.key
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [each.value]

  # AKS delegates its pod subnet to itself; declaring it here stops plans from undoing that.
  # The name must match what AKS writes ("aks-delegation"), or every plan shows drift.
  dynamic "delegation" {
    for_each = each.key == "aks-pods" ? [1] : []
    content {
      name = "aks-delegation"
      service_delegation {
        name    = "Microsoft.ContainerService/managedClusters"
        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }
    }
  }
}

output "subnet_ids" {
  value = { for k, s in azurerm_subnet.this : k => s.id }
}

# ==================== VPN gateway (slowest resource in the project: 30–45 min) ====================

variable "azure_asn" {
  type    = number
  default = 65515
}

variable "azure_apipa_addresses" {
  description = "Azure-side BGP IPs, one per AWS tunnel (.2 of each /30)"
  type        = list(string)
  default     = ["169.254.21.2", "169.254.22.2"]
}

resource "azurerm_public_ip" "vpngw" {
  name                = "${var.project}-vpngw-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  # No zones: northcentralus has no availability zones, so a zone list would be rejected
  tags = local.tags
}

resource "azurerm_virtual_network_gateway" "vpngw" {
  name                = "${var.project}-vpngw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  type          = "Vpn"
  vpn_type      = "RouteBased"
  sku           = "VpnGw1AZ" # Basic has no BGP; non-AZ VpnGw1 can't be created since Nov 2025. Runs regional in a no-AZ region.
  generation    = "Generation1"
  active_active = false
  bgp_enabled   = true

  ip_configuration {
    name                          = "vnetGatewayConfig"
    public_ip_address_id          = azurerm_public_ip.vpngw.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.this["GatewaySubnet"].id
  }

  bgp_settings {
    asn = var.azure_asn
    peering_addresses {
      ip_configuration_name = "vnetGatewayConfig"
      apipa_addresses       = var.azure_apipa_addresses
    }
  }

  tags = local.tags

  # Azure locks the VNet while a gateway builds (30–45 min), so any subnet created
  # in parallel fails with ReferencedResourceNotProvisioned. Make all subnets first.
  depends_on = [azurerm_subnet.this]
}

output "vpn_gateway_id" {
  value = azurerm_virtual_network_gateway.vpngw.id
}

output "vpn_gateway_public_ip" {
  value = azurerm_public_ip.vpngw.ip_address
}

output "azure_asn" {
  value = var.azure_asn
}
