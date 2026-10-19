# AWS network: VPC, subnets, single NAT gateway, and the VGW for the Azure VPN.

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
    key = "aws/network.tfstate"
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
    tags = { Project = var.project, ManagedBy = "terraform", Layer = "aws-network" }
  }
}

# ==================== VPC, subnets, NAT, VGW ====================
# One registry module builds all of these; the VGW inputs/outputs are grouped below it.

variable "vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-2a", "us-east-2b"]
}

variable "private_subnets" {
  description = "Large /19s: EKS pods take VPC IPs"
  type        = list(string)
  default     = ["10.10.0.0/19", "10.10.32.0/19"]
}

variable "public_subnets" {
  type    = list(string)
  default = ["10.10.64.0/24", "10.10.65.0/24"]
}

variable "cluster_name" {
  description = "EKS cluster name, used for subnet discovery tags"
  type        = string
  default     = "cloudbridge-eks"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.project}-vpc"
  cidr = var.vpc_cidr
  azs  = var.azs

  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  # Cost: one NAT gateway instead of one per AZ
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_support   = true
  enable_dns_hostnames = true

  # VPN gateway for the Azure tunnel; BGP routes propagate into private route tables
  enable_vpn_gateway                 = true
  amazon_side_asn                    = var.amazon_side_asn
  propagate_private_route_tables_vgw = true

  # Subnet discovery for the AWS Load Balancer Controller
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "private_route_table_ids" {
  value = module.vpc.private_route_table_ids
}

# ==================== VPN gateway (VGW) ====================

variable "amazon_side_asn" {
  type    = string
  default = "64512"
}

output "vgw_id" {
  value = module.vpc.vgw_id
}

output "amazon_side_asn" {
  value = var.amazon_side_asn
}
