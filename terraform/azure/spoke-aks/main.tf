# Azure AKS spoke: spoke VNet peered to the hub (using the hub VPN gateway), UDRs that send
# everything through the hub firewall, private DNS links, and a Storage Private Endpoint.
# There is no AKS public IP: the student quota allows only 3 public IPs, and all 3 are used
# by the 2 VPN gateway instances and the firewall. Users reach AKS by DNAT on the firewall
# to the AKS internal load balancer (10.20.4.10) in the ilb subnet.

# ==================== Setup ====================

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  # State lives in the same S3 bucket as the AWS layers
  backend "s3" {
    key = "azure/spoke-aks.tfstate"
  }
}

variable "project" {
  type    = string
  default = "cloudbridge"
}

variable "aws_region" {
  description = "Region of the S3 state bucket"
  type        = string
  default     = "us-east-2"
}

locals {
  tags = { Project = var.project, ManagedBy = "terraform", Layer = "azure-spoke-aks" }
}

# Only used to find the state bucket
provider "aws" {
  region = var.aws_region
}

# Subscription comes from ARM_SUBSCRIPTION_ID
provider "azurerm" {
  features {}
  # Providers (Network, Compute, ContainerService, ...) were registered once by hand
  resource_provider_registrations = "none"
}

# ==================== Inputs from the hub ====================

# Same naming rule as bootstrap, so nobody has to pass the bucket name in
data "aws_caller_identity" "current" {}

data "terraform_remote_state" "hub" {
  backend = "s3"
  config = {
    bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
    key    = "azure/hub.tfstate"
    region = var.aws_region
  }
}

locals {
  hub = data.terraform_remote_state.hub.outputs
}

# ==================== Spoke VNet ====================

variable "spoke_cidr" {
  type    = string
  default = "10.20.0.0/20"
}

variable "subnets" {
  type = map(string)
  default = {
    aks-nodes = "10.20.0.0/22"
    ilb       = "10.20.4.0/27" # AKS internal LB uses 10.20.4.10
    pe        = "10.20.5.0/27"
  }
}

resource "azurerm_virtual_network" "spoke" {
  name                = "${var.project}-spoke-aks"
  location            = local.hub.location
  resource_group_name = local.hub.resource_group_name
  address_space       = [var.spoke_cidr]
  # Hub DNS pattern: every spoke resolves through the hub firewall's forwarder. That gives AKS
  # cross-cloud names (cloudbridge.internal -> AWS) with no CoreDNS changes, and lets Test 6 build
  # an FQDN egress allowlist (dnsmasq fills nftables sets from the names the nodes look up).
  # Set at creation: nodes only pick up a DNS change after a reboot.
  dns_servers = [local.hub.fw_ip]
  tags        = local.tags
}

resource "azurerm_subnet" "this" {
  for_each             = var.subnets
  name                 = each.key
  resource_group_name  = local.hub.resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [each.value]
  # Without this, UDRs are ignored for Private Endpoint traffic
  private_endpoint_network_policies = each.key == "pe" ? "Enabled" : "Disabled"
}

# ==================== Peering ====================
# The spoke uses the hub VPN gateway (gateway transit), so AWS routes reach the spoke.
# The hub gateway already exists when this layer is applied.

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                         = "hub-to-spoke-aks"
  resource_group_name          = local.hub.resource_group_name
  virtual_network_name         = local.hub.hub_vnet_name
  remote_virtual_network_id    = azurerm_virtual_network.spoke.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                         = "spoke-aks-to-hub"
  resource_group_name          = local.hub.resource_group_name
  virtual_network_name         = azurerm_virtual_network.spoke.name
  remote_virtual_network_id    = local.hub.hub_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = true

  # use_remote_gateways fails unless the hub side already allows gateway transit
  depends_on = [azurerm_virtual_network_peering.hub_to_spoke]
}

# ==================== Routing ====================
# Spoke: everything goes to the hub firewall. BGP propagation is off so the routes to AWS
# learned by the VPN gateway can't bypass the firewall.

resource "azurerm_route_table" "spoke" {
  name                          = "${var.project}-spoke-aks"
  location                      = local.hub.location
  resource_group_name           = local.hub.resource_group_name
  bgp_route_propagation_enabled = false
  tags                          = local.tags

  route {
    name                   = "default-via-fw"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.hub.fw_ip
  }
}

resource "azurerm_subnet_route_table_association" "spoke" {
  for_each       = azurerm_subnet.this
  subnet_id      = each.value.id
  route_table_id = azurerm_route_table.spoke.id
}

# GatewaySubnet: VPN -> spoke traffic also goes through the firewall, so both directions
# are inspected (symmetric). Lives here because this layer knows the spoke prefix.
# BGP propagation must stay on, or the gateway loses its routes to AWS.

resource "azurerm_route_table" "gateway" {
  name                          = "${var.project}-gatewaysubnet"
  location                      = local.hub.location
  resource_group_name           = local.hub.resource_group_name
  bgp_route_propagation_enabled = true
  tags                          = local.tags

  route {
    name                   = "spoke-aks-via-fw"
    address_prefix         = var.spoke_cidr
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.hub.fw_ip
  }
}

resource "azurerm_subnet_route_table_association" "gateway" {
  subnet_id      = local.hub.gateway_subnet_id
  route_table_id = azurerm_route_table.gateway.id
}

# ==================== Private DNS links ====================
# Both hub zones (in the hub RG) are linked to the spoke so AKS resolves them too.

resource "azurerm_private_dns_zone_virtual_network_link" "spoke" {
  for_each              = local.hub.private_dns_zone_names
  name                  = "spoke-aks"
  resource_group_name   = local.hub.resource_group_name
  private_dns_zone_name = each.value
  virtual_network_id    = azurerm_virtual_network.spoke.id
  tags                  = local.tags
}

# ==================== Private Endpoint to hub Storage ====================

resource "azurerm_private_endpoint" "blob" {
  name                = "${var.project}-blob-pe"
  location            = local.hub.location
  resource_group_name = local.hub.resource_group_name
  subnet_id           = azurerm_subnet.this["pe"].id
  tags                = local.tags

  private_service_connection {
    name                           = "blob"
    private_connection_resource_id = local.hub.storage_account_id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  # Registers the endpoint's A record in privatelink.blob.core.windows.net
  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [local.hub.private_dns_zone_ids["privatelink.blob.core.windows.net"]]
  }
}

# ==================== Flow logs ====================
# VNet flow logs (NSG flow logs are retired). Network Watcher already exists in the region.

resource "azurerm_network_watcher_flow_log" "spoke" {
  name                 = "${var.project}-spoke-aks"
  network_watcher_name = "NetworkWatcher_${local.hub.location}"
  resource_group_name  = "NetworkWatcherRG"
  target_resource_id   = azurerm_virtual_network.spoke.id
  storage_account_id   = local.hub.storage_account_id
  enabled              = true
  version              = 2
  tags                 = local.tags

  retention_policy {
    enabled = true
    days    = 7
  }
}

# ==================== Outputs ====================

output "spoke_vnet_id" {
  value = azurerm_virtual_network.spoke.id
}

output "spoke_vnet_name" {
  value = azurerm_virtual_network.spoke.name
}

output "subnet_ids" {
  value = { for k, s in azurerm_subnet.this : k => s.id }
}

output "route_table_id" {
  value = azurerm_route_table.spoke.id
}

output "private_endpoint_ip" {
  value = azurerm_private_endpoint.blob.private_service_connection[0].private_ip_address
}
