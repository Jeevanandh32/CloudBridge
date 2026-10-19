# Global DNS: Route 53 health checks and failover records for app.<domain>.
# PRIMARY = AWS ALB, SECONDARY = Azure LB.

# ==================== Setup ====================

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
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

# ==================== Inputs: hosted zone and both clouds' endpoints ====================

variable "domain" {
  description = "Registered domain; its hosted zone was created by Route 53 at registration"
  type        = string
  default     = "jeevs.click"
}

data "aws_caller_identity" "current" {}

data "terraform_remote_state" "aks" {
  backend = "s3"
  config = {
    bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
    key    = "azure/aks.tfstate"
    region = var.region
  }
}

# Read-only lookup: destroying this layer never touches the zone or the domain
data "aws_route53_zone" "public" {
  name = var.domain
}

# The ALB is created by the AWS Load Balancer Controller, not Terraform; find it by the
# tags the controller puts on it (namespace/ingress-name)
data "aws_lb" "frontend" {
  tags = {
    "elbv2.k8s.aws/cluster" = "cloudbridge-eks"
    "ingress.k8s.aws/stack" = "cloudbridge/frontend"
  }
}

locals {
  azure_ip = data.terraform_remote_state.aks.outputs.frontend_public_ip
}

# ==================== Health checks ====================

variable "health_check_interval" {
  description = "Seconds between checks from each Route 53 checker: 10 (fast) or 30 (standard)"
  type        = number
  default     = 10
}

variable "health_check_failures" {
  description = "Consecutive failures before an endpoint is marked unhealthy"
  type        = number
  default     = 3
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

# ==================== Failover records ====================

variable "app_name" {
  type    = string
  default = "app"
}

variable "ttl" {
  description = "TTL of the Azure record; resolvers may keep the old answer this long after failover"
  type        = number
  default     = 30
}

locals {
  fqdn = "${var.app_name}.${var.domain}"
}

# PRIMARY answers while AWS is healthy. The health check, not the alias target's own
# health, decides — so the decision is the same deep /health check for both clouds.
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

output "app_url" {
  value = "http://${local.fqdn}/"
}
