# EKS: the cluster and node group, its image registry, the Load Balancer Controller's IAM
# role, and the private DNS zone the app's backend lives in.

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
    key = "aws/eks.tfstate"
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
    tags = { Project = var.project, ManagedBy = "terraform", Layer = "aws-eks" }
  }
}

# ==================== Inputs from other layers ====================

data "aws_caller_identity" "current" {}

locals {
  state_bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = local.state_bucket
    key    = "aws/network.tfstate"
    region = var.region
  }
}

# Only for the Azure VNet CIDR, so the node security group can allow it
data "terraform_remote_state" "azure" {
  backend = "s3"
  config = {
    bucket = local.state_bucket
    key    = "azure/network.tfstate"
    region = var.region
  }
}

locals {
  network         = data.terraform_remote_state.network.outputs
  azure_vnet_cidr = data.terraform_remote_state.azure.outputs.vnet_cidr
}

output "vpc_id" {
  description = "Needed by the AWS Load Balancer Controller Helm install"
  value       = local.network.vpc_id
}

# ==================== EKS cluster + node group ====================

variable "cluster_name" {
  description = "Must match cluster_name in aws/network (used in subnet discovery tags)"
  type        = string
  default     = "cloudbridge-eks"
}

variable "kubernetes_version" {
  description = "Stay in standard support: older versions bill extended-support pricing"
  type        = string
  default     = "1.35"
}

variable "service_cidr" {
  type    = string
  default = "172.20.0.0/16"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_count" {
  type    = number
  default = 2
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  # Public endpoint so kubectl works from a laptop; nodes still use the private one
  endpoint_public_access  = true
  endpoint_private_access = true

  # The IAM identity running Terraform becomes cluster admin
  enable_cluster_creator_admin_permissions = true

  vpc_id            = local.network.vpc_id
  subnet_ids        = local.network.private_subnet_ids
  service_ipv4_cidr = var.service_cidr

  # Cost: no KMS key and no control-plane logs in CloudWatch for a short-lived lab
  encryption_config           = null
  create_kms_key              = false
  enabled_log_types           = []
  create_cloudwatch_log_group = false

  # vpc-cni must exist before nodes join, or they never become Ready.
  # Pod identity agent is for the AWS Load Balancer Controller.
  addons = {
    vpc-cni = {
      before_compute = true
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]

      # Fixed size: no autoscaling, so the node-failure test measures Kubernetes, not scaling
      min_size     = var.node_count
      max_size     = var.node_count + 1
      desired_size = var.node_count
    }
  }

  # Let Azure reach pods directly over the VPN (VPC CNI gives pods VPC IPs)
  node_security_group_additional_rules = {
    azure_vnet = {
      description = "All traffic from the Azure VNet over the VPN"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      cidr_blocks = [local.azure_vnet_cidr]
    }
  }
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

# ==================== ECR image registry ====================

# In-region image registry: EKS never depends on another cloud to pull images.
# Nodes can already pull from it (the module attaches AmazonEC2ContainerRegistryReadOnly).
resource "aws_ecr_repository" "app" {
  name                 = "${var.project}-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # Lets `terraform destroy` remove it even with images inside
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

# ==================== AWS Load Balancer Controller IAM (Pod Identity) ====================

# IAM role for the AWS Load Balancer Controller, handed out through EKS Pod Identity:
# only the controller's service account can assume it, not every pod on the node
module "aws_lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                            = "${var.project}-aws-lbc"
  attach_aws_lb_controller_policy = true

  associations = {
    controller = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

# ==================== Private DNS zone (cloudbridge.internal) ====================

# Private DNS for the app's dependency. The frontend reaches the backend at
# backend.cloudbridge.internal; Test 1 empties that record to reproduce the Oct 2025
# outage (healthy servers, but a dependency's DNS name stops resolving).
resource "aws_route53_zone" "internal" {
  name          = "cloudbridge.internal"
  force_destroy = true # The backend record is managed by the deploy/test scripts

  vpc {
    vpc_id = local.network.vpc_id
  }
}

variable "negative_cache_ttl" {
  description = "Seconds resolvers may cache 'name does not exist' (NXDOMAIN). Route 53's default is 900"
  type        = number
  default     = 30
}

# Resolvers cache NXDOMAIN for min(SOA TTL, SOA minimum) (RFC 2308). With Route 53's default
# SOA (TTL 900, minimum 86400) that's 15 minutes: Test 1 run 1 showed failback stuck for
# minutes after the record was restored. Short values make a restored record usable fast.
# Trade-off: more queries reach the resolver for names that really don't exist.
resource "aws_route53_record" "internal_soa" {
  zone_id         = aws_route53_zone.internal.zone_id
  name            = aws_route53_zone.internal.name
  type            = "SOA"
  ttl             = var.negative_cache_ttl
  allow_overwrite = true # The zone already has a default SOA; take it over

  # primary-NS admin-email serial refresh retry expire minimum. Copied from Route 53's default
  # SOA for private zones (its primary NS is always ns-1536.awsdns-00.co.uk.; the zone's
  # primary_name_server attribute only returns a placeholder). Only TTL and minimum change.
  records = ["ns-1536.awsdns-00.co.uk. awsdns-hostmaster.amazon.com. 1 7200 900 1209600 ${var.negative_cache_ttl}"]
}

output "internal_zone_id" {
  value = aws_route53_zone.internal.zone_id
}
