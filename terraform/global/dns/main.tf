# Global DNS (Test 1): app.<domain> served by TWO DNS providers, so neither is a single point
# of failure.
#   Route 53:  failover records, PRIMARY = AWS ALB, SECONDARY = Azure firewall public IP
#   Azure DNS: CNAME -> Traffic Manager (Priority), priority 1 = ALB, priority 2 = Azure firewall
# The registrar delegates the domain to 2 Route 53 + 2 Azure DNS name servers. A resolver
# that can't reach one provider retries against the other and gets the same answer.

# ==================== Setup ====================

terraform {
  # 1.17 for lifecycle { destroy = false } (forget on destroy, see the apex NS records)
  required_version = ">= 1.17"
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
  backend "s3" {
    key = "global/dns.tfstate"
  }
}

variable "project" {
  type    = string
  default = "cloudbridge"
}

variable "region" {
  type    = string
  default = "us-east-2"
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.project, ManagedBy = "terraform", Layer = "global-dns" }
  }
}

# Route 53 Domains (the registrar API) only exists in us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = { Project = var.project, ManagedBy = "terraform", Layer = "global-dns" }
  }
}

# Subscription comes from ARM_SUBSCRIPTION_ID
provider "azurerm" {
  features {}
  # Providers (Network, ...) were registered once by hand
  resource_provider_registrations = "none"
}

# Used ONLY by the Azure apex NS record. Azure creates that record set with the zone, so a
# normal create fails with "already exists - needs to be imported". This flag makes create
# overwrite it instead. Kept on an alias so no other resource can silently overwrite anything.
provider "azurerm" {
  alias = "overwrite"
  features {
    skip_import_check_on_create_and_allow_overwriting_existing_resources = true
  }
  resource_provider_registrations = "none"
}

# ==================== Inputs: zone and both clouds' endpoints ====================

variable "domain" {
  description = "Registered domain; its Route 53 hosted zone was created at registration"
  type        = string
  default     = "jeevs.click"
}

data "aws_caller_identity" "current" {}

data "azurerm_client_config" "current" {}

data "terraform_remote_state" "hub" {
  backend = "s3"
  config = {
    bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
    key    = "azure/hub.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
    key    = "aws/eks.tfstate"
    region = var.region
  }
}

# Read-only lookup: the zone exists outside Terraform; destroying this layer never touches it
data "aws_route53_zone" "public" {
  name = var.domain
}

# The ALB is created by the AWS Load Balancer Controller, not Terraform; find it by the
# tags the controller puts on it (namespace/ingress-name)
data "aws_lb" "frontend" {
  tags = {
    "elbv2.k8s.aws/cluster" = data.terraform_remote_state.eks.outputs.cluster_name
    "ingress.k8s.aws/stack" = "cloudbridge/frontend"
  }
}

locals {
  hub = data.terraform_remote_state.hub.outputs

  # Azure entry point: the firewall's public IP; its DNAT forwards :80 to the AKS internal LB
  azure_ip = local.hub.fw_public_ip
}

# ==================== Health checks (shared settings) ====================

variable "health_check_interval" {
  description = "Seconds between checks: 10 (fast) or 30 (standard). Used by Route 53 AND Traffic Manager"
  type        = number
  default     = 10
}

variable "health_check_failures" {
  description = "Consecutive failures before an endpoint is marked unhealthy (both providers)"
  type        = number
  default     = 3
}

variable "health_check_timeout" {
  description = "Traffic Manager probe timeout in seconds (5-9 allowed with a 10 s interval). Route 53's is fixed at 4 s"
  type        = number
  default     = 5
}

# Deep checks live here, at the global layer: /health fails if the frontend can't reach
# its backend, so a broken dependency (Test 1) or a dead region (Test 2) both trigger failover
resource "aws_route53_health_check" "aws" {
  fqdn              = data.aws_lb.frontend.dns_name
  type              = "HTTP"
  port              = 80
  resource_path     = "/health"
  request_interval  = var.health_check_interval
  failure_threshold = var.health_check_failures
  tags              = { Name = "${var.project}-aws" }
}

resource "aws_route53_health_check" "azure" {
  ip_address        = local.azure_ip
  type              = "HTTP"
  port              = 80
  resource_path     = "/health"
  request_interval  = var.health_check_interval
  failure_threshold = var.health_check_failures
  tags              = { Name = "${var.project}-azure" }
}

output "health_check_ids" {
  value = {
    aws   = aws_route53_health_check.aws.id
    azure = aws_route53_health_check.azure.id
  }
}

# ==================== Provider 1: Route 53 failover records ====================

variable "app_name" {
  type    = string
  default = "app"
}

variable "ttl" {
  description = "TTL of the Azure answer (both providers); resolvers may keep the old answer this long after failover"
  type        = number
  default     = 30
}

locals {
  fqdn = "${var.app_name}.${var.domain}"
}

# PRIMARY answers while AWS is healthy. The health check, not the alias target's own
# health, decides — so the decision is the same deep /health check for both clouds.
# An alias has no TTL of its own: it inherits the ALB's fixed 60 s.
resource "aws_route53_record" "primary" {
  zone_id         = data.aws_route53_zone.public.zone_id
  name            = local.fqdn
  type            = "A"
  set_identifier  = "aws"
  health_check_id = aws_route53_health_check.aws.id

  failover_routing_policy {
    type = "PRIMARY"
  }

  alias {
    name                   = data.aws_lb.frontend.dns_name
    zone_id                = data.aws_lb.frontend.zone_id
    evaluate_target_health = false
  }
}

# SECONDARY answers only when PRIMARY is unhealthy. Already running (warm standby):
# failover is a DNS answer change, no launches or control-plane calls needed.
resource "aws_route53_record" "secondary" {
  zone_id         = data.aws_route53_zone.public.zone_id
  name            = local.fqdn
  type            = "A"
  ttl             = var.ttl
  records         = [local.azure_ip]
  set_identifier  = "azure"
  health_check_id = aws_route53_health_check.azure.id

  failover_routing_policy {
    type = "SECONDARY"
  }
}

# ==================== Provider 2: Azure DNS zone + Traffic Manager ====================

# Same name as the Route 53 zone, hosted on Azure's own name servers. A DNS zone is global;
# the resource group only holds it.
resource "azurerm_dns_zone" "public" {
  name                = var.domain
  resource_group_name = local.hub.resource_group_name
  tags                = { Project = var.project, ManagedBy = "terraform", Layer = "global-dns" }
}

# Same failover outcome as Route 53:
#   - same deep /health check, same interval (10 s) and failure count (3)
#   - Priority routing: the lowest healthy priority wins, so AWS while healthy, else Azure
#   - failback only once AWS passes checks again
#   - all endpoints unhealthy: Route 53 answers PRIMARY, and Traffic Manager treats a fully
#     degraded profile as all-healthy, so it also answers priority 1. Both fail open to AWS.
resource "azurerm_traffic_manager_profile" "app" {
  # relative_name is global across Azure (<name>.trafficmanager.net), so add a stable suffix
  name                   = "${var.project}-app"
  resource_group_name    = local.hub.resource_group_name
  traffic_routing_method = "Priority"

  dns_config {
    relative_name = "${var.project}-app-${substr(md5(data.azurerm_client_config.current.subscription_id), 0, 6)}"
    ttl           = var.ttl
  }

  monitor_config {
    protocol                     = "HTTP"
    port                         = 80
    path                         = "/health"
    interval_in_seconds          = var.health_check_interval
    timeout_in_seconds           = var.health_check_timeout
    tolerated_number_of_failures = var.health_check_failures
  }

  tags = { Project = var.project, ManagedBy = "terraform", Layer = "global-dns" }
}

# Hostname target: Traffic Manager answers with a CNAME to the ALB, whose own records keep
# AWS's 60 s TTL (same as the Route 53 alias)
resource "azurerm_traffic_manager_external_endpoint" "aws" {
  name       = "aws-alb"
  profile_id = azurerm_traffic_manager_profile.app.id
  target     = data.aws_lb.frontend.dns_name
  priority   = 1
}

# Both endpoints are DNS names: Traffic Manager rejects a profile that mixes IPv4 and DomainName targets.
# Its answer for app is then a CNAME chain ending in the firewall IP's A record.
resource "azurerm_traffic_manager_external_endpoint" "azure" {
  name       = "azure-fw"
  profile_id = azurerm_traffic_manager_profile.app.id
  target     = data.terraform_remote_state.hub.outputs.fw_public_fqdn # DNS name, not IP: TM can't mix IPv4 and DomainName targets
  priority   = 2
}

resource "azurerm_dns_cname_record" "app" {
  name                = var.app_name
  zone_name           = azurerm_dns_zone.public.name
  resource_group_name = local.hub.resource_group_name
  ttl                 = var.ttl
  record              = azurerm_traffic_manager_profile.app.fqdn
}

# ==================== Name servers: delegation set ====================

locals {
  # The 4 servers Route 53 assigned to the zone (its delegation set, not the apex record,
  # so this stays the same after the apex NS is overwritten below)
  route53_ns = sort(data.aws_route53_zone.public.name_servers)
  # Azure returns FQDNs with a trailing dot
  azure_ns = sort([for ns in azurerm_dns_zone.public.name_servers : trimsuffix(ns, ".")])

  # Delegation: 2 + 2. Sorted (ns-... before ns1-/ns2-) so the registrar's sorted answer
  # never shows a diff. Each pair is on 2 different TLDs (.net/.org, .com/.net).
  delegation_ns = sort(concat(slice(local.route53_ns, 0, 2), slice(local.azure_ns, 0, 2)))
}

# ==================== Apex NS: each zone lists the other provider too ====================

variable "apex_ns_ttl" {
  description = "TTL of both apex NS record sets; matches the .click TLD's 900 s NS TTL"
  type        = number
  default     = 900
}

# Route 53 lets you replace the apex NS freely; allow_overwrite turns create into UPSERT.
# It lists exactly the delegation set (2 Route 53 + 2 Azure), matching the registrar.
# Destroy: Route 53 never deletes a zone's apex NS (the provider ignores the
# InvalidChangeBatch error), so this record is only forgotten. It keeps the Azure servers
# after destroy: run restore_apex_ns_command afterwards.
resource "aws_route53_record" "apex_ns" {
  zone_id         = data.aws_route53_zone.public.zone_id
  name            = var.domain
  type            = "NS"
  ttl             = var.apex_ns_ttl
  records         = local.delegation_ns
  allow_overwrite = true

  lifecycle {
    destroy = false
  }
}

# Azure allows ADDING servers to the apex NS set (for co-hosting with another provider) and
# changing its TTL, but not removing or changing its own 4 pre-populated servers, and the set
# can't be deleted separately (it goes with the zone). So this set is Azure's 4 + the same 2
# Route 53 servers as the registrar: 6 in total, a superset of the delegation.
#   - create: the set already exists, so it needs the overwrite provider alias (see Setup)
#   - destroy: deleting "@" NS fails, so it is only forgotten; the zone's deletion removes it
resource "azurerm_dns_ns_record" "apex" {
  provider            = azurerm.overwrite
  name                = "@"
  zone_name           = azurerm_dns_zone.public.name
  resource_group_name = local.hub.resource_group_name
  ttl                 = var.apex_ns_ttl
  records             = [for ns in concat(local.azure_ns, slice(local.route53_ns, 0, 2)) : "${ns}."]

  lifecycle {
    destroy = false
  }
}

# ==================== Registrar delegation ====================

# Adopts the existing registration (it is never created, transferred or deleted here) and
# sets its name servers to the 2 + 2 delegation set. The .click TLD serves these NS records
# with a 900 s TTL, so resolvers can keep the old delegation up to 15 min after a change.
#
# DESTROY DOES NOT RESET THE NAME SERVERS: it only removes the resource from state, and the
# registrar keeps pointing at 2 Azure servers that no longer exist once the Azure zone is
# gone. After every destroy, run the restore_nameservers_command output (runbook step).
resource "aws_route53domains_registered_domain" "this" {
  provider    = aws.us_east_1
  domain_name = var.domain

  # HARD REQUIREMENT: auto-renew stays OFF. Set explicitly so Terraform can never turn it on.
  auto_renew = false

  # Lock is off on the registration today; the provider's default (true) would change it
  transfer_lock = false

  dynamic "name_server" {
    for_each = local.delegation_ns
    content {
      name = name_server.value
    }
  }
}

# ==================== Outputs ====================

output "app_fqdn" {
  value = local.fqdn
}

output "app_url" {
  value = "http://${local.fqdn}/"
}

output "route53_nameservers" {
  value = local.route53_ns
}

output "azure_nameservers" {
  value = local.azure_ns
}

output "delegation_nameservers" {
  description = "What the registrar hands out: 2 Route 53 + 2 Azure DNS"
  value       = local.delegation_ns
}

output "traffic_manager_fqdn" {
  value = azurerm_traffic_manager_profile.app.fqdn
}

# Ask each provider directly, bypassing every cache: both must give the same answer
output "dig_route53" {
  value = "dig @${local.route53_ns[0]} ${local.fqdn} +norecurse"
}

output "dig_azure" {
  value = "dig @${local.azure_ns[0]} ${local.fqdn} +norecurse"
}

# Run after destroy: point the registrar back at Route 53 only
output "restore_nameservers_command" {
  value = "aws route53domains update-domain-nameservers --region us-east-1 --domain-name ${var.domain} --nameservers ${join(" ", [for ns in local.route53_ns : "Name=${ns}"])}"
}

# Run after destroy: put the Route 53 apex NS back to its own 4 servers (Route 53's default TTL)
output "restore_apex_ns_command" {
  value = "aws route53 change-resource-record-sets --hosted-zone-id ${data.aws_route53_zone.public.zone_id} --change-batch '${jsonencode({ Changes = [{ Action = "UPSERT", ResourceRecordSet = { Name = var.domain, Type = "NS", TTL = 172800, ResourceRecords = [for ns in local.route53_ns : { Value = "${ns}." }] } }] })}'"
}
