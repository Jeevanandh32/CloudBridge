# AWS app spoke: the VPC that EKS and the ALB live in, attached to the Transit Gateway.
# Inbound comes straight from the internet to the ALB here; everything outbound
# (internet and Azure) goes to the TGW and through the inspection VPC firewalls.

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
    key = "aws/spoke-app.tfstate"
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
    tags = { Project = var.project, ManagedBy = "terraform", Layer = "aws-spoke-app" }
  }
}

data "aws_caller_identity" "current" {}

data "terraform_remote_state" "hub" {
  backend = "s3"
  config = {
    bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
    key    = "aws/hub.tfstate"
    region = var.region
  }
}

locals {
  hub = data.terraform_remote_state.hub.outputs
}

# ==================== VPC and subnets ====================

variable "vpc_cidr" {
  type    = string
  default = "10.10.0.0/20"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-2a", "us-east-2b"]
}

variable "node_subnets" {
  description = "EKS nodes and (by default) pods. /26 on purpose: Test 5 runs these out of IPs."
  type        = list(string)
  default     = ["10.10.0.0/26", "10.10.0.64/26"]
}

variable "public_subnets" {
  description = "ALB only"
  type        = list(string)
  default     = ["10.10.4.0/24", "10.10.5.0/24"]
}

variable "tgw_subnets" {
  type    = list(string)
  default = ["10.10.15.0/28", "10.10.15.16/28"]
}

variable "enable_secondary_cidr" {
  description = "Test 5 fix: add 10.10.64.0/18 and give pods their own subnets (VPC CNI custom networking)"
  type        = bool
  default     = false
}

variable "secondary_cidr" {
  type    = string
  default = "10.10.64.0/18"
}

variable "pod_subnets" {
  description = "Pod subnets in the secondary CIDR, created only when enable_secondary_cidr = true"
  type        = list(string)
  default     = ["10.10.64.0/19", "10.10.96.0/19"]
}

variable "cluster_name" {
  description = "EKS cluster name, for load balancer subnet discovery tags"
  type        = string
  default     = "cloudbridge-eks"
}

resource "aws_vpc" "app" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-app" }
}

resource "aws_vpc_ipv4_cidr_block_association" "secondary" {
  count      = var.enable_secondary_cidr ? 1 : 0
  vpc_id     = aws_vpc.app.id
  cidr_block = var.secondary_cidr
}

resource "aws_internet_gateway" "app" {
  vpc_id = aws_vpc.app.id
  tags   = { Name = "${var.project}-app-igw" }
}

resource "aws_subnet" "node" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.app.id
  cidr_block        = var.node_subnets[count.index]
  availability_zone = var.azs[count.index]
  tags = {
    Name                                        = "${var.project}-app-node-${substr(var.azs[count.index], -1, 1)}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "pod" {
  count             = var.enable_secondary_cidr ? length(var.azs) : 0
  vpc_id            = aws_vpc.app.id
  cidr_block        = var.pod_subnets[count.index]
  availability_zone = var.azs[count.index]
  tags              = { Name = "${var.project}-app-pod-${substr(var.azs[count.index], -1, 1)}" }
  depends_on        = [aws_vpc_ipv4_cidr_block_association.secondary]
}

resource "aws_subnet" "public" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.app.id
  cidr_block        = var.public_subnets[count.index]
  availability_zone = var.azs[count.index]
  tags = {
    Name                                        = "${var.project}-app-public-${substr(var.azs[count.index], -1, 1)}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "tgw" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.app.id
  cidr_block        = var.tgw_subnets[count.index]
  availability_zone = var.azs[count.index]
  tags              = { Name = "${var.project}-app-tgw-${substr(var.azs[count.index], -1, 1)}" }
}

# ==================== Transit Gateway attachment ====================

resource "aws_ec2_transit_gateway_vpc_attachment" "app" {
  transit_gateway_id                              = local.hub.tgw_id
  vpc_id                                          = aws_vpc.app.id
  subnet_ids                                      = aws_subnet.tgw[*].id
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "${var.project}-att-app" }
}

# This spoke uses the "spokes" table (0.0.0.0/0 -> inspection)
resource "aws_ec2_transit_gateway_route_table_association" "app" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.app.id
  transit_gateway_route_table_id = local.hub.tgw_route_table_ids["spokes"]
}

# The inspection table learns this VPC's CIDRs (including the secondary one once added)
variable "propagate_to_inspection" {
  description = "Test 4 break A sets this to false: the firewalls lose the route back to this spoke"
  type        = bool
  default     = true
}

resource "aws_ec2_transit_gateway_route_table_propagation" "app_to_inspection" {
  count                          = var.propagate_to_inspection ? 1 : 0
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.app.id
  transit_gateway_route_table_id = local.hub.tgw_route_table_ids["inspection"]
}

# Traffic from Azure must go through the firewalls first, so the VPN table points this
# spoke's CIDRs at the inspection VPC (static) instead of learning them by propagation.
# The TGW advertises these routes to Azure over BGP.
locals {
  spoke_cidrs = concat([var.vpc_cidr], var.enable_secondary_cidr ? [var.secondary_cidr] : [])
}

resource "aws_ec2_transit_gateway_route" "vpn_to_app" {
  for_each                       = toset(local.spoke_cidrs)
  destination_cidr_block         = each.value
  transit_gateway_attachment_id  = local.hub.inspection_attachment_id
  transit_gateway_route_table_id = local.hub.tgw_route_table_ids["vpn"]
}

# ==================== VPC routing ====================

# Nodes, pods and TGW subnets: everything not local goes to the TGW
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.app.id
  tags   = { Name = "${var.project}-app-private" }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = local.hub.tgw_id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.app]
}

resource "aws_route_table_association" "node" {
  count          = length(aws_subnet.node)
  subnet_id      = aws_subnet.node[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "pod" {
  count          = length(aws_subnet.pod)
  subnet_id      = aws_subnet.pod[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "tgw" {
  count          = length(aws_subnet.tgw)
  subnet_id      = aws_subnet.tgw[count.index].id
  route_table_id = aws_route_table.private.id
}

# Public subnets: the ALB answers internet clients directly through this VPC's IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.app.id
  tags   = { Name = "${var.project}-app-public" }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.app.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ==================== Private access to S3 ====================

# Gateway endpoint: free, keeps in-VPC S3 traffic (image layers, logs) off the firewall NAT
resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id            = aws_vpc.app.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "${var.project}-s3-gateway" }
}

# Interface endpoint (PrivateLink) in one AZ: lets Azure reach S3 over the VPN with no
# internet path. Its endpoint-specific DNS name resolves publicly to these private IPs.
resource "aws_security_group" "s3_interface" {
  name        = "${var.project}-s3-interface"
  description = "HTTPS to the S3 interface endpoint from Azure"
  vpc_id      = aws_vpc.app.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.20.0.0/16", var.vpc_cidr]
  }

  tags = { Name = "${var.project}-s3-interface" }
}

resource "aws_vpc_endpoint" "s3_interface" {
  vpc_id              = aws_vpc.app.id
  service_name        = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.node[0].id] # 1 AZ: half the hourly cost
  security_group_ids  = [aws_security_group.s3_interface.id]
  private_dns_enabled = false # the gateway endpoint already serves the VPC
  tags                = { Name = "${var.project}-s3-interface" }
}

# A small object to read privately from Azure
resource "aws_s3_bucket" "probe" {
  bucket_prefix = "${var.project}-probe-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "probe" {
  bucket                  = aws_s3_bucket.probe.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Readable without credentials, but only through the interface endpoint. A policy that is
# conditioned on aws:SourceVpce does not count as public, so the public access block allows it.
resource "aws_s3_bucket_policy" "probe" {
  bucket = aws_s3_bucket.probe.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ReadViaPrivateLinkOnly"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.probe.arn}/*"
      Condition = { StringEquals = { "aws:SourceVpce" = aws_vpc_endpoint.s3_interface.id } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.probe]
}

resource "aws_s3_object" "probe" {
  bucket       = aws_s3_bucket.probe.id
  key          = "hello.txt"
  content      = "hello from AWS S3 over PrivateLink\n"
  content_type = "text/plain"
}

# ==================== Private DNS ====================
# cloudbridge.internal: private zone for AWS names. Associated with the inspection VPC as
# well, so the firewalls' DNS forwarder can answer Azure's queries for it.

resource "aws_route53_zone" "internal" {
  name          = "cloudbridge.internal"
  force_destroy = true

  vpc {
    vpc_id = aws_vpc.app.id
  }

  vpc {
    vpc_id = local.hub.inspection_vpc_id
  }
}

resource "aws_route53_record" "fw" {
  for_each = { a = local.hub.fw_ips[0], b = local.hub.fw_ips[1] }
  zone_id  = aws_route53_zone.internal.zone_id
  name     = "fw-${each.key}.cloudbridge.internal"
  type     = "A"
  ttl      = 60
  records  = [each.value]
}

# ==================== Flow logs (rejected only) ====================

resource "aws_flow_log" "app" {
  vpc_id                   = aws_vpc.app.id
  traffic_type             = "REJECT"
  log_destination_type     = "s3"
  log_destination          = local.hub.flowlog_bucket_arn
  max_aggregation_interval = 60
  tags                     = { Name = "${var.project}-app" }
}

# ==================== Test hosts ====================
# Session 1 has no clusters, so one tiny host per AZ gives Tests 3 and 4 something to reach.
# Each serves its own name on :80 (Test 4 counts which flows succeed). Managed via SSM.

variable "enable_test_hosts" {
  type    = bool
  default = true
}

variable "test_host_ips" {
  type    = list(string)
  default = ["10.10.0.10", "10.10.0.74"]
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

resource "aws_iam_role" "host" {
  count = var.enable_test_hosts ? 1 : 0
  name  = "${var.project}-test-host"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "host_ssm" {
  count      = var.enable_test_hosts ? 1 : 0
  role       = aws_iam_role.host[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  count = var.enable_test_hosts ? 1 : 0
  name  = "${var.project}-test-host"
  role  = aws_iam_role.host[0].name
}

resource "aws_security_group" "host" {
  count       = var.enable_test_hosts ? 1 : 0
  name        = "${var.project}-test-host"
  description = "Test hosts: anything from private ranges"
  vpc_id      = aws_vpc.app.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "host" {
  count                  = var.enable_test_hosts ? length(var.azs) : 0
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = "t4g.nano"
  subnet_id              = aws_subnet.node[count.index].id
  private_ip             = var.test_host_ips[count.index]
  vpc_security_group_ids = [aws_security_group.host[0].id]
  iam_instance_profile   = aws_iam_instance_profile.host[0].name

  # No internet access is needed to start this: python3 ships with Ubuntu
  user_data = <<-EOT
    #!/bin/bash
    mkdir -p /srv/www && hostname > /srv/www/index.html
    cat > /etc/systemd/system/probe-web.service <<'UNIT'
    [Unit]
    Description=CloudBridge probe web server
    After=network-online.target
    [Service]
    ExecStart=/usr/bin/python3 -m http.server 80 --directory /srv/www
    Restart=always
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload && systemctl enable --now probe-web
  EOT

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = "${var.project}-app-host-${substr(var.azs[count.index], -1, 1)}" }

  lifecycle {
    ignore_changes = [ami]
  }
}

# ==================== Outputs ====================

output "test_host_ips" {
  value = aws_instance.host[*].private_ip
}

output "test_host_ids" {
  value = aws_instance.host[*].id
}

output "vpc_id" {
  value = aws_vpc.app.id
}

output "vpc_cidrs" {
  value = local.spoke_cidrs
}

output "node_subnet_ids" {
  value = aws_subnet.node[*].id
}

output "pod_subnet_ids" {
  value = aws_subnet.pod[*].id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "app_attachment_id" {
  value = aws_ec2_transit_gateway_vpc_attachment.app.id
}

output "internal_zone_id" {
  value = aws_route53_zone.internal.zone_id
}

output "s3_interface_dns" {
  description = "Use as https://<bucket>.bucket.<this without *.>/hello.txt from Azure (the literal bucket. label is required for the TLS certificate)"
  value       = aws_vpc_endpoint.s3_interface.dns_entry[0].dns_name
}

output "probe_bucket" {
  value = aws_s3_bucket.probe.bucket
}
