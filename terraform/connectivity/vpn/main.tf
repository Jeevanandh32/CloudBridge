# Site-to-site VPN, active-active: Azure VPN gateway (2 instances) <-> AWS Transit Gateway.
#
# 2 customer gateways (one per Azure instance public IP) and 2 VPN connections on the TGW,
# each with 2 IPsec (IKEv2) tunnels running eBGP 64512 <-> 65515 = 4 tunnels:
#
#   connection  Azure instance  tunnel  inside CIDR        AWS BGP IP     Azure BGP IP
#   c0          instance0       t1      169.254.21.0/30    169.254.21.1   169.254.21.2
#   c0          instance0       t2      169.254.22.0/30    169.254.22.1   169.254.22.2
#   c1          instance1       t1      169.254.21.4/30    169.254.21.5   169.254.21.6
#   c1          instance1       t2      169.254.22.4/30    169.254.22.5   169.254.22.6
#
# Azure side: one local network gateway + one connection per AWS tunnel (4 of each).
# The TGW spreads traffic over all 4 with ECMP; losing one Azure instance costs 2 tunnels.

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
  # Providers were registered once by hand; see azure/hub
  resource_provider_registrations = "none"
}

# ==================== Inputs from the hub layers ====================

# Same naming rule as bootstrap, so nobody has to pass the bucket name in
data "aws_caller_identity" "current" {}

locals {
  state_bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

data "terraform_remote_state" "aws" {
  backend = "s3"
  config = {
    bucket = local.state_bucket
    key    = "aws/hub.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "azure" {
  backend = "s3"
  config = {
    bucket = local.state_bucket
    key    = "azure/hub.tfstate"
    region = var.aws_region
  }
}

locals {
  aws   = data.terraform_remote_state.aws.outputs
  azure = data.terraform_remote_state.azure.outputs
}

# ==================== Tunnel layout ====================

variable "tunnel_inside_cidrs" {
  description = "Per VPN connection, tunnel1 and tunnel2 inside CIDRs. The .2 of each /30 must match the apipa map in azure/hub (index 0 = 169.254.21.x, index 1 = 169.254.22.x)."
  type        = map(list(string))
  default = {
    c0 = ["169.254.21.0/30", "169.254.22.0/30"] # Azure instance0: .2
    c1 = ["169.254.21.4/30", "169.254.22.4/30"] # Azure instance1: .6
  }
}

locals {
  # Which Azure gateway instance each AWS VPN connection terminates on
  connections = {
    c0 = "instance0"
    c1 = "instance1"
  }

  # Static keys (c0-t1 ...), so for_each never depends on values known only after apply
  tunnel_keys = flatten([for c in keys(local.connections) : ["${c}-t1", "${c}-t2"]])
}

# ==================== Pre-shared keys ====================

# AWS PSK rules: 8–64 chars, letters/digits/._ only, must not start with 0 (hence the "cb" prefix)
resource "random_password" "psk" {
  for_each = toset(local.tunnel_keys)
  length   = 32
  special  = false
}

# ==================== AWS side: customer gateways + VPN connections on the TGW ====================

resource "aws_customer_gateway" "azure" {
  for_each   = local.connections
  bgp_asn    = local.azure.azure_asn
  ip_address = local.azure.vpn_gateway_public_ips[each.value]
  type       = "ipsec.1"
  tags       = { Name = "${var.project}-cgw-azure-${each.key}" }
}

resource "aws_vpn_connection" "azure" {
  for_each            = local.connections
  transit_gateway_id  = local.aws.tgw_id
  customer_gateway_id = aws_customer_gateway.azure[each.key].id
  type                = "ipsec.1"
  static_routes_only  = false # BGP

  tunnel1_inside_cidr   = var.tunnel_inside_cidrs[each.key][0]
  tunnel2_inside_cidr   = var.tunnel_inside_cidrs[each.key][1]
  tunnel1_preshared_key = "cb${random_password.psk["${each.key}-t1"].result}"
  tunnel2_preshared_key = "cb${random_password.psk["${each.key}-t2"].result}"
  tunnel1_ike_versions  = ["ikev2"]
  tunnel2_ike_versions  = ["ikev2"]

  tags = { Name = "${var.project}-vpn-azure-${each.key}" }

  lifecycle {
    # Catch a drift between this layer's inside CIDRs and the APIPA addresses azure/hub configured
    precondition {
      condition = alltrue([
        for i in [0, 1] :
        cidrhost(var.tunnel_inside_cidrs[each.key][i], 2) == local.azure.apipa[each.value][i]
      ])
      error_message = "The .2 of each tunnel inside CIDR must equal the azure/hub apipa address for that instance."
    }
  }
}

# --- Transit Gateway wiring ---
# Default association/propagation are off on this TGW, so both are explicit:
#   associate with "vpn"         -> traffic from Azure is routed by the vpn table (spokes -> inspection)
#   propagate into "inspection"  -> the firewalls learn the Azure prefixes over BGP

resource "aws_ec2_transit_gateway_route_table_association" "vpn" {
  for_each                       = aws_vpn_connection.azure
  transit_gateway_attachment_id  = each.value.transit_gateway_attachment_id
  transit_gateway_route_table_id = local.aws.tgw_route_table_ids["vpn"]
}

resource "aws_ec2_transit_gateway_route_table_propagation" "vpn_to_inspection" {
  for_each                       = aws_vpn_connection.azure
  transit_gateway_attachment_id  = each.value.transit_gateway_attachment_id
  transit_gateway_route_table_id = local.aws.tgw_route_table_ids["inspection"]
}

output "vpn_connection_ids" {
  value = { for k, v in aws_vpn_connection.azure : k => v.id }
}

output "vpn_attachment_ids" {
  value = { for k, v in aws_vpn_connection.azure : k => v.transit_gateway_attachment_id }
}

# ==================== Azure side: local network gateways + connections ====================

# Per-tunnel values AWS only knows after creating the VPN connections
locals {
  tunnels = merge([
    for c, instance in local.connections : {
      for i in [1, 2] : "${c}-t${i}" => {
        azure_instance = instance
        outside_ip     = i == 1 ? aws_vpn_connection.azure[c].tunnel1_address : aws_vpn_connection.azure[c].tunnel2_address
        aws_bgp_ip     = i == 1 ? aws_vpn_connection.azure[c].tunnel1_vgw_inside_address : aws_vpn_connection.azure[c].tunnel2_vgw_inside_address
        az_bgp_ip      = i == 1 ? aws_vpn_connection.azure[c].tunnel1_cgw_inside_address : aws_vpn_connection.azure[c].tunnel2_cgw_inside_address
        psk            = i == 1 ? aws_vpn_connection.azure[c].tunnel1_preshared_key : aws_vpn_connection.azure[c].tunnel2_preshared_key
        # An active-active gateway needs one APIPA per instance on every connection; the
        # instance that actually terminates this tunnel uses its own (= az_bgp_ip), the other is unused.
        bgp_primary   = local.azure.apipa["instance0"][i - 1]
        bgp_secondary = local.azure.apipa["instance1"][i - 1]
      }
    }
  ]...)
}

# One local network gateway per AWS tunnel endpoint
resource "azurerm_local_network_gateway" "aws" {
  for_each            = toset(local.tunnel_keys)
  name                = "${var.project}-lng-aws-${each.key}"
  location            = local.azure.location
  resource_group_name = local.azure.resource_group_name
  gateway_address     = local.tunnels[each.key].outside_ip

  bgp_settings {
    asn                 = tonumber(local.aws.amazon_side_asn)
    bgp_peering_address = local.tunnels[each.key].aws_bgp_ip
  }

  tags = local.tags
}

resource "azurerm_virtual_network_gateway_connection" "aws" {
  for_each            = toset(local.tunnel_keys)
  name                = "${var.project}-conn-aws-${each.key}"
  location            = local.azure.location
  resource_group_name = local.azure.resource_group_name

  type                       = "IPsec"
  connection_protocol        = "IKEv2"
  virtual_network_gateway_id = local.azure.vpn_gateway_id
  local_network_gateway_id   = azurerm_local_network_gateway.aws[each.key].id
  shared_key                 = local.tunnels[each.key].psk
  bgp_enabled                = true

  # Azure must use the APIPA address AWS expects on this tunnel:
  # primary = instance0's address, secondary = instance1's address
  custom_bgp_addresses {
    primary   = local.tunnels[each.key].bgp_primary
    secondary = local.tunnels[each.key].bgp_secondary
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
      azure_instance = t.azure_instance
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

# --- AWS side: CloudWatch on each VPN connection's TunnelState ---
# For a BGP VPN, TunnelState is 1 only when the tunnel is up AND its BGP session is established;
# averaged across a connection's 2 tunnels it is 0.5 when one is down and 0 when both are.

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
  for_each            = aws_vpn_connection.azure
  alarm_name          = "${var.project}-vpn-${each.key}-degraded"
  alarm_description   = "A tunnel (or its BGP session) on VPN connection ${each.key} is down; ECMP carries traffic on the others. Runbook: docs/runbook.md#vpn-degraded"
  namespace           = "AWS/VPN"
  metric_name         = "TunnelState"
  dimensions          = { VpnId = each.value.id }
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
  for_each            = aws_vpn_connection.azure
  alarm_name          = "${var.project}-vpn-${each.key}-down"
  alarm_description   = "Both tunnels on VPN connection ${each.key} are down (Azure ${local.connections[each.key]} unreachable); the other connection still carries traffic. Runbook: docs/runbook.md#vpn-down"
  namespace           = "AWS/VPN"
  metric_name         = "TunnelState"
  dimensions          = { VpnId = each.value.id }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = 0
  treat_missing_data  = "breaching" # no data at all from a live VPN is itself a problem
  alarm_actions       = [aws_sns_topic.vpn_alerts.arn]
  ok_actions          = [aws_sns_topic.vpn_alerts.arn]
}

# Whole private link down: the best tunnel across both connections is 0, i.e. all 4 are down
resource "aws_cloudwatch_metric_alarm" "vpn_link_down" {
  alarm_name          = "${var.project}-vpn-link-down"
  alarm_description   = "All 4 VPN tunnels are down; no private path between AWS and Azure. Public traffic is unaffected. Runbook: docs/runbook.md#vpn-down"
  evaluation_periods  = 1
  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = 0
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.vpn_alerts.arn]
  ok_actions          = [aws_sns_topic.vpn_alerts.arn]

  metric_query {
    id          = "best"
    expression  = "MAX([${join(", ", [for k in keys(aws_vpn_connection.azure) : "m_${k}"])}])"
    label       = "Best TunnelState across all tunnels"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = aws_vpn_connection.azure
    content {
      id = "m_${metric_query.key}"
      metric {
        namespace   = "AWS/VPN"
        metric_name = "TunnelState"
        dimensions  = { VpnId = metric_query.value.id }
        stat        = "Maximum"
        period      = 300
      }
    }
  }
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

# One time series per BGP peer (169.254.21.1, .22.1, .21.5, .22.5): 1 = connected, 0 = not
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
    aws_degraded  = { for k, a in aws_cloudwatch_metric_alarm.vpn_degraded : k => a.alarm_name }
    aws_down      = { for k, a in aws_cloudwatch_metric_alarm.vpn_down : k => a.alarm_name }
    aws_link_down = aws_cloudwatch_metric_alarm.vpn_link_down.alarm_name
    azure_bgp     = azurerm_monitor_metric_alert.bgp_peer_down.name
  }
}
