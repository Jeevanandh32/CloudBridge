# Azure hub: resource group, hub VNet, active-active VPN gateway (2 public IPs), firewall VM
# (the 3rd and last public IP the student quota allows), private DNS zones, flow-log storage.
# The VPN gateway takes 30–45 minutes: apply this layer first in every session.

# ==================== Setup ====================

terraform {
  required_version = ">= 1.10"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
  # State lives in the same S3 bucket as the AWS layers
  backend "s3" {
    key = "azure/hub.tfstate"
  }
}

# Subscription comes from ARM_SUBSCRIPTION_ID
provider "azurerm" {
  features {}
  # Providers (Network, Compute, ContainerService, ...) were registered once by hand
  resource_provider_registrations = "none"
}

variable "project" {
  type    = string
  default = "cloudbridge"
}

variable "location" {
  description = "Student subscription policy allows only a few regions; northcentralus is closest to AWS us-east-2"
  type        = string
  default     = "northcentralus"
}

locals {
  tags = { Project = var.project, ManagedBy = "terraform", Layer = "azure-hub" }
}

resource "azurerm_resource_group" "rg" {
  name     = "${var.project}-rg"
  location = var.location
  tags     = local.tags
}

# ==================== Hub VNet ====================

variable "hub_cidr" {
  type    = string
  default = "10.20.240.0/22"
}

variable "subnets" {
  type = map(string)
  default = {
    GatewaySubnet = "10.20.240.0/27" # name required by Azure
    fw            = "10.20.241.0/28"
  }
}

resource "azurerm_virtual_network" "hub" {
  name                = "${var.project}-hub"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.hub_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "this" {
  for_each             = var.subnets
  name                 = each.key
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [each.value]
}

# ==================== VPN gateway, active-active ====================
# Two gateway instances, each with its own public IP. AWS builds one VPN connection to each
# (2 tunnels each = 4 tunnels). Losing one instance costs half the tunnels, not the link.

variable "azure_asn" {
  type    = number
  default = 65515
}

variable "apipa" {
  description = "Azure-side BGP IPs per instance; must match the AWS tunnel inside CIDRs in connectivity/vpn"
  type        = map(list(string))
  default = {
    instance0 = ["169.254.21.2", "169.254.22.2"]
    instance1 = ["169.254.21.6", "169.254.22.6"]
  }
}

resource "azurerm_public_ip" "vpngw" {
  for_each            = toset(["instance0", "instance1"])
  name                = "${var.project}-vpngw-${each.key}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  # No zones: northcentralus has no availability zones
  tags = local.tags
}

resource "azurerm_virtual_network_gateway" "vpngw" {
  name                = "${var.project}-vpngw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  type          = "Vpn"
  vpn_type      = "RouteBased"
  sku           = "VpnGw1AZ" # Basic has no BGP; non-AZ VpnGw1 can't be created since Nov 2025
  generation    = "Generation1"
  active_active = true # no extra gateway charge, one more public IP
  bgp_enabled   = true

  dynamic "ip_configuration" {
    for_each = azurerm_public_ip.vpngw
    content {
      name                          = ip_configuration.key
      public_ip_address_id          = ip_configuration.value.id
      private_ip_address_allocation = "Dynamic"
      subnet_id                     = azurerm_subnet.this["GatewaySubnet"].id
    }
  }

  bgp_settings {
    asn = var.azure_asn
    dynamic "peering_addresses" {
      for_each = var.apipa
      content {
        ip_configuration_name = peering_addresses.key
        apipa_addresses       = peering_addresses.value
      }
    }
  }

  tags = local.tags

  # Azure locks the VNet while the gateway builds, so create every subnet first
  depends_on = [azurerm_subnet.this]
}

# ==================== Firewall VM ====================
# Ubuntu + nftables, one NIC with IP forwarding. Does SNAT for outbound, DNAT for inbound
# (health checks and users reach AKS through it), MSS clamp, and DNS forwarding.
# Managed with `az vm run-command`: no SSH port is open.

variable "fw_ip" {
  type    = string
  default = "10.20.241.4"
}

variable "fw_size" {
  description = "2 vCPU Basv2: with the 1 AKS node this uses the whole 4 vCPU B-series quota"
  type        = string
  default     = "Standard_B2ats_v2"
}

variable "aws_fw_ips" {
  description = "AWS firewalls' DNS forwarders (fw-a, fw-b in aws/hub)"
  type        = list(string)
  default     = ["10.10.240.40", "10.10.240.56"]
}

variable "aks_ilb_ip" {
  description = "Internal load balancer IP the AKS service will use (spoke ILB subnet)"
  type        = string
  default     = "10.20.4.10"
}

variable "pe_subnet" {
  description = "Private Endpoint subnet in the spoke; traffic to it is SNATed so replies return through this firewall"
  type        = string
  default     = "10.20.5.0/27"
}

variable "mss_clamp" {
  type    = number
  default = 1360
}

resource "azurerm_public_ip" "fw" {
  name                = "${var.project}-fw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  # A DNS name for the firewall IP: Traffic Manager can't mix IP and DNS-name external
  # endpoints in one profile, and the AWS endpoint is the ALB's DNS name (found in Session 3).
  domain_name_label = "${var.project}-fw-${substr(random_string.sa.result, 0, 6)}"
  tags              = local.tags
}

# Standard public IPs deny inbound unless an NSG allows it
resource "azurerm_network_security_group" "fw" {
  name                = "${var.project}-fw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags

  security_rule {
    name                       = "private-in"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = "10.0.0.0/8"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "*"
  }

  security_rule {
    name                       = "http-in"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "Internet"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_range     = "80"
  }
}

resource "azurerm_subnet_network_security_group_association" "fw" {
  subnet_id                 = azurerm_subnet.this["fw"].id
  network_security_group_id = azurerm_network_security_group.fw.id
}

resource "azurerm_network_interface" "fw" {
  name                  = "${var.project}-fw"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  ip_forwarding_enabled = true # forward packets not addressed to this NIC
  tags                  = local.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.this["fw"].id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.fw_ip
    public_ip_address_id          = azurerm_public_ip.fw.id
  }
}

# Azure requires a key even though access is via run-command; it is never output
resource "tls_private_key" "fw" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "fw" {
  name                  = "${var.project}-fw"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  size                  = var.fw_size
  admin_username        = "cbadmin"
  network_interface_ids = [azurerm_network_interface.fw.id]
  tags                  = local.tags

  admin_ssh_key {
    username   = "cbadmin"
    public_key = tls_private_key.fw.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/fw-cloud-init.yaml.tftpl", {
    fw_ip      = var.fw_ip
    aws_fw_ips = var.aws_fw_ips
    ilb_ip     = var.aks_ilb_ip
    pe_subnet  = var.pe_subnet
    mss        = var.mss_clamp
  }))

  boot_diagnostics {} # enables the serial console for emergencies

  lifecycle {
    # A cloud-init change would otherwise replace the only Azure firewall mid-session (all
    # Azure ingress, AKS egress and Azure DNS go through it). New builds pick up template
    # changes; to roll one onto a running firewall, apply it live with run-command.
    ignore_changes = [custom_data]
  }
}

# ==================== Private DNS ====================
# az.cloudbridge.internal: Azure-side private names. privatelink.blob...: the Private Endpoint
# in the spoke registers here. Both are linked to the hub so the firewall's forwarder
# (which asks 168.63.129.16) can answer AWS's queries.

resource "azurerm_private_dns_zone" "this" {
  for_each            = toset(["az.cloudbridge.internal", "privatelink.blob.core.windows.net"])
  name                = each.key
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub" {
  for_each              = azurerm_private_dns_zone.this
  name                  = "hub"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.hub.id
  tags                  = local.tags
}

resource "azurerm_private_dns_a_record" "fw" {
  name                = "fw"
  zone_name           = azurerm_private_dns_zone.this["az.cloudbridge.internal"].name
  resource_group_name = azurerm_resource_group.rg.name
  ttl                 = 60
  records             = [var.fw_ip]
}

# ==================== Storage: flow logs + Private Endpoint target ====================

resource "random_string" "sa" {
  length  = 8
  upper   = false
  special = false
}

resource "azurerm_storage_account" "hub" {
  name                     = "cbhub${random_string.sa.result}"
  location                 = azurerm_resource_group.rg.location
  resource_group_name      = azurerm_resource_group.rg.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  tags                     = local.tags
}

resource "azurerm_storage_container" "probe" {
  name                  = "probe"
  storage_account_id    = azurerm_storage_account.hub.id
  container_access_type = "private"
}

resource "azurerm_storage_blob" "probe" {
  name                   = "hello.txt"
  storage_account_name   = azurerm_storage_account.hub.name
  storage_container_name = azurerm_storage_container.probe.name
  type                   = "Block"
  source_content         = "hello from Azure Blob over Private Endpoint\n"
  content_type           = "text/plain"
}

# VNet flow logs (NSG flow logs are retired). Network Watcher already exists in the region.
resource "azurerm_network_watcher_flow_log" "hub" {
  name                 = "${var.project}-hub"
  network_watcher_name = "NetworkWatcher_${var.location}"
  resource_group_name  = "NetworkWatcherRG"
  target_resource_id   = azurerm_virtual_network.hub.id
  storage_account_id   = azurerm_storage_account.hub.id
  enabled              = true
  version              = 2
  tags                 = local.tags

  retention_policy {
    enabled = true
    days    = 7
  }
}

# ==================== Outputs ====================

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "location" {
  value = azurerm_resource_group.rg.location
}

output "hub_vnet_id" {
  value = azurerm_virtual_network.hub.id
}

output "hub_vnet_name" {
  value = azurerm_virtual_network.hub.name
}

output "hub_cidr" {
  value = var.hub_cidr
}

output "gateway_subnet_id" {
  value = azurerm_subnet.this["GatewaySubnet"].id
}

output "vpn_gateway_id" {
  value = azurerm_virtual_network_gateway.vpngw.id
}

output "vpn_gateway_public_ips" {
  description = "instance0, instance1"
  value       = { for k, ip in azurerm_public_ip.vpngw : k => ip.ip_address }
}

output "apipa" {
  value = var.apipa
}

output "azure_asn" {
  value = var.azure_asn
}

output "fw_ip" {
  value = var.fw_ip
}

output "fw_public_ip" {
  value = azurerm_public_ip.fw.ip_address
}

output "fw_public_fqdn" {
  value = azurerm_public_ip.fw.fqdn
}

output "fw_vm_name" {
  value = azurerm_linux_virtual_machine.fw.name
}

output "private_dns_zone_ids" {
  value = { for k, z in azurerm_private_dns_zone.this : k => z.id }
}

output "private_dns_zone_names" {
  value = { for k, z in azurerm_private_dns_zone.this : k => z.name }
}

output "storage_account_id" {
  value = azurerm_storage_account.hub.id
}

output "storage_account_name" {
  value = azurerm_storage_account.hub.name
}
