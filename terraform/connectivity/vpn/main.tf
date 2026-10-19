# Site-to-site VPN: 2 IPsec (IKEv2) tunnels with BGP between the AWS VGW and the Azure gateway.

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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  backend "s3" {
    key = "connectivity/vpn.tfstate"
  }
}

variable "project" {
  type    = string
  default = "cloudbridge"
}

variable "aws_region" {
  type    = string
  default = "us-east-2"
}

locals {
  tags = { Project = var.project, ManagedBy = "terraform", Layer = "vpn" }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.tags
  }
}

provider "azurerm" {
  features {}
  # Providers were registered once by hand; see azure/network
  resource_provider_registrations = "none"
}

# ==================== Inputs from the network layers ====================

# Same naming rule as bootstrap, so nobody has to pass the bucket name in
data "aws_caller_identity" "current" {}

locals {
  state_bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

data "terraform_remote_state" "aws" {
  backend = "s3"
  config = {
    bucket = local.state_bucket
    key    = "aws/network.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "azure" {
  backend = "s3"
  config = {
    bucket = local.state_bucket
    key    = "azure/network.tfstate"
    region = var.aws_region
  }
}

locals {
  aws   = data.terraform_remote_state.aws.outputs
  azure = data.terraform_remote_state.azure.outputs
}

# ==================== Pre-shared keys ====================

# AWS PSK rules: 8–64 chars, letters/digits/._ only, must not start with 0
resource "random_password" "psk" {
  count   = 2
  length  = 32
  special = false
}

# ==================== AWS side: customer gateway + VPN connection ====================

variable "tunnel_inside_cidrs" {
  description = "Must match azure_apipa_addresses in azure/network (.2 of each /30)"
  type        = list(string)
  default     = ["169.254.21.0/30", "169.254.22.0/30"]
}

resource "aws_customer_gateway" "azure" {
  bgp_asn    = local.azure.azure_asn
  ip_address = local.azure.vpn_gateway_public_ip
  type       = "ipsec.1"
  tags       = { Name = "${var.project}-cgw-azure" }
}

resource "aws_vpn_connection" "azure" {
  vpn_gateway_id      = local.aws.vgw_id
  customer_gateway_id = aws_customer_gateway.azure.id
  type                = "ipsec.1"
  static_routes_only  = false # BGP

  tunnel1_inside_cidr   = var.tunnel_inside_cidrs[0]
  tunnel2_inside_cidr   = var.tunnel_inside_cidrs[1]
  tunnel1_preshared_key = "cb${random_password.psk[0].result}"
  tunnel2_preshared_key = "cb${random_password.psk[1].result}"
  tunnel1_ike_versions  = ["ikev2"]
  tunnel2_ike_versions  = ["ikev2"]

  tags = { Name = "${var.project}-vpn-azure" }
}

output "vpn_connection_id" {
  value = aws_vpn_connection.azure.id
}

# ==================== Azure side: local network gateways + connections ====================

# Per-tunnel values AWS only knows after creating the VPN connection
locals {
  tunnels = {
    t1 = {
      outside_ip = aws_vpn_connection.azure.tunnel1_address
      aws_bgp_ip = aws_vpn_connection.azure.tunnel1_vgw_inside_address
      az_bgp_ip  = aws_vpn_connection.azure.tunnel1_cgw_inside_address
      psk        = aws_vpn_connection.azure.tunnel1_preshared_key
    }
    t2 = {
      outside_ip = aws_vpn_connection.azure.tunnel2_address
      aws_bgp_ip = aws_vpn_connection.azure.tunnel2_vgw_inside_address
      az_bgp_ip  = aws_vpn_connection.azure.tunnel2_cgw_inside_address
      psk        = aws_vpn_connection.azure.tunnel2_preshared_key
    }
  }
}

# One local network gateway per AWS tunnel endpoint
resource "azurerm_local_network_gateway" "aws" {
  for_each            = local.tunnels
  name                = "${var.project}-lng-aws-${each.key}"
  location            = local.azure.location
  resource_group_name = local.azure.resource_group_name
  gateway_address     = each.value.outside_ip

  bgp_settings {
    asn                 = tonumber(local.aws.amazon_side_asn)
    bgp_peering_address = each.value.aws_bgp_ip
  }

  tags = local.tags
}

resource "azurerm_virtual_network_gateway_connection" "aws" {
  for_each            = local.tunnels
  name                = "${var.project}-conn-aws-${each.key}"
  location            = local.azure.location
  resource_group_name = local.azure.resource_group_name

  type                       = "IPsec"
  connection_protocol        = "IKEv2"
  virtual_network_gateway_id = local.azure.vpn_gateway_id
  local_network_gateway_id   = azurerm_local_network_gateway.aws[each.key].id
  shared_key                 = each.value.psk
  bgp_enabled                = true

  # Azure must use the APIPA address AWS expects on this tunnel
  custom_bgp_addresses {
    primary = each.value.az_bgp_ip
  }

  tags = local.tags
}

# PSKs are deliberately not output
output "tunnels" {
  value = {
    for k, t in local.tunnels : k => {
      aws_outside_ip = t.outside_ip
      aws_bgp_ip     = t.aws_bgp_ip
      azure_bgp_ip   = t.az_bgp_ip
    }
  }
}

# ==================== Monitoring: tunnel and BGP alarms ====================
# Each cloud watches its own side, so an alert still fires if the other cloud is the one that broke.
# Runbook for every alarm: docs/runbook.md

variable "alert_email" {
  description = "Where VPN alarms are emailed (set in terraform.tfvars, which git ignores)"
  type        = string
}

# --- AWS side: CloudWatch on the VPN connection's TunnelState ---
# For a BGP VPN, TunnelState is 1 only when the tunnel is up AND its BGP session is established;
# averaged across both tunnels it is 0.5 when one is down and 0 when both are.

resource "aws_sns_topic" "vpn_alerts" {
  name = "${var.project}-vpn-alerts"
}

# Email subscriptions stay "pending" until the link in AWS's confirmation email is clicked
resource "aws_sns_topic_subscription" "vpn_alerts_email" {
  topic_arn = aws_sns_topic.vpn_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "vpn_degraded" {
  alarm_name          = "${var.project}-vpn-degraded"
  alarm_description   = "One VPN tunnel (or its BGP session) is down; traffic is on the other tunnel. Runbook: docs/runbook.md#vpn-degraded"
  namespace           = "AWS/VPN"
  metric_name         = "TunnelState"
  dimensions          = { VpnId = aws_vpn_connection.azure.id }
  statistic           = "Average"
  period              = 300 # AWS publishes VPN metrics every 5 minutes
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.vpn_alerts.arn]
  ok_actions          = [aws_sns_topic.vpn_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "vpn_down" {
  alarm_name          = "${var.project}-vpn-down"
  alarm_description   = "Both VPN tunnels are down; no private path between AWS and Azure. Public traffic is unaffected. Runbook: docs/runbook.md#vpn-down"
  namespace           = "AWS/VPN"
  metric_name         = "TunnelState"
  dimensions          = { VpnId = aws_vpn_connection.azure.id }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = 0
  treat_missing_data  = "breaching" # no data at all from a live VPN is itself a problem
  alarm_actions       = [aws_sns_topic.vpn_alerts.arn]
  ok_actions          = [aws_sns_topic.vpn_alerts.arn]
}

# --- Azure side: Azure Monitor on the gateway's BGP peers ---

resource "azurerm_monitor_action_group" "vpn_alerts" {
  name                = "${var.project}-vpn-alerts"
  resource_group_name = local.azure.resource_group_name
  short_name          = "cbvpn" # max 12 chars, shown in SMS/email
  tags                = local.tags

  email_receiver {
    name          = "owner"
    email_address = var.alert_email
  }
}

# One time series per BGP peer (169.254.21.1 and .22.1): 1 = connected, 0 = not
resource "azurerm_monitor_metric_alert" "bgp_peer_down" {
  name                = "${var.project}-bgp-peer-down"
  resource_group_name = local.azure.resource_group_name
  scopes              = [local.azure.vpn_gateway_id]
  description         = "A BGP session from the Azure VPN gateway to AWS is down (IPsec may still be up). Runbook: docs/runbook.md#bgp-peer-down"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.Network/virtualNetworkGateways"
    metric_name      = "BgpPeerStatus"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 1

    dimension {
      name     = "BgpPeerAddress"
      operator = "Include"
      values   = [for t in local.tunnels : t.aws_bgp_ip]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.vpn_alerts.id
  }
}

output "alarms" {
  value = {
    aws_degraded = aws_cloudwatch_metric_alarm.vpn_degraded.alarm_name
    aws_down     = aws_cloudwatch_metric_alarm.vpn_down.alarm_name
    azure_bgp    = azurerm_monitor_metric_alert.bgp_peer_down.name
  }
}
