# AWS hub: Transit Gateway, inspection VPC with two firewall VMs (fw-a, fw-b), and flow logs.
# Every spoke and the VPN attach to the Transit Gateway; all traffic between them and all
# internet egress passes through a firewall.

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
    key = "aws/hub.tfstate"
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
    tags = { Project = var.project, ManagedBy = "terraform", Layer = "aws-hub" }
  }
}

# ==================== Transit Gateway ====================
# Default association/propagation are off so every route table is explicit: a route only
# exists because this code (or a spoke layer) put it there. Test 4 relies on that.

variable "amazon_side_asn" {
  type    = number
  default = 64512
}

resource "aws_ec2_transit_gateway" "tgw" {
  description                     = "${var.project} hub"
  amazon_side_asn                 = var.amazon_side_asn
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  vpn_ecmp_support                = "enable" # spread traffic over all 4 tunnels
  dns_support                     = "enable"
  tags                            = { Name = "${var.project}-tgw" }
}

# Three route tables, one per role:
#   spokes      associated with app VPCs:    0.0.0.0/0 -> inspection
#   vpn         associated with VPN attachments: spoke CIDRs -> inspection (static, added by spokes)
#   inspection  associated with the inspection VPC: learns spokes + Azure by propagation
resource "aws_ec2_transit_gateway_route_table" "this" {
  for_each           = toset(["spokes", "vpn", "inspection"])
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  tags               = { Name = "${var.project}-tgw-rt-${each.key}" }
}

# ==================== Inspection VPC ====================

variable "inspection_cidr" {
  type    = string
  default = "10.10.240.0/24"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-2a", "us-east-2b"]
}

variable "tgw_subnets" {
  description = "Transit Gateway attachment subnets, one per AZ"
  type        = list(string)
  default     = ["10.10.240.0/28", "10.10.240.16/28"]
}

variable "fw_subnets" {
  description = "Public firewall subnets, one per AZ"
  type        = list(string)
  default     = ["10.10.240.32/28", "10.10.240.48/28"]
}

variable "fw_ips" {
  description = "Fixed firewall IPs (fw-a, fw-b). The Azure firewall forwards DNS to these."
  type        = list(string)
  default     = ["10.10.240.40", "10.10.240.56"]
}

resource "aws_vpc" "inspection" {
  cidr_block           = var.inspection_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-inspection" }
}

resource "aws_internet_gateway" "inspection" {
  vpc_id = aws_vpc.inspection.id
  tags   = { Name = "${var.project}-inspection-igw" }
}

resource "aws_subnet" "tgw" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.inspection.id
  cidr_block        = var.tgw_subnets[count.index]
  availability_zone = var.azs[count.index]
  tags              = { Name = "${var.project}-inspection-tgw-${substr(var.azs[count.index], -1, 1)}" }
}

resource "aws_subnet" "fw" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.inspection.id
  cidr_block        = var.fw_subnets[count.index]
  availability_zone = var.azs[count.index]
  tags              = { Name = "${var.project}-inspection-fw-${substr(var.azs[count.index], -1, 1)}" }
}

# ==================== Inspection VPC attachment ====================

variable "appliance_mode" {
  description = "Test 4 break B sets this to \"disable\": flows crossing AZs then return through the other firewall and get dropped"
  type        = string
  default     = "enable"
}

resource "aws_ec2_transit_gateway_vpc_attachment" "inspection" {
  transit_gateway_id                              = aws_ec2_transit_gateway.tgw.id
  vpc_id                                          = aws_vpc.inspection.id
  subnet_ids                                      = aws_subnet.tgw[*].id
  appliance_mode_support                          = var.appliance_mode
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "${var.project}-att-inspection" }
}

resource "aws_ec2_transit_gateway_route_table_association" "inspection" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this["inspection"].id
}

# The VPN route table learns the inspection VPC, so Azure can reach the firewalls' DNS forwarders
resource "aws_ec2_transit_gateway_route_table_propagation" "inspection_to_vpn" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this["vpn"].id
}

# Spokes send everything (Azure and internet) to the inspection VPC
resource "aws_ec2_transit_gateway_route" "spokes_default" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this["spokes"].id
}

# ==================== Inspection VPC routing ====================
# TGW subnet in AZ x -> firewall in AZ x. Firewall subnets -> internet, or back to the TGW for 10/8.

resource "aws_route_table" "tgw" {
  count  = length(var.azs)
  vpc_id = aws_vpc.inspection.id
  tags   = { Name = "${var.project}-inspection-tgw-${substr(var.azs[count.index], -1, 1)}" }
}

resource "aws_route" "tgw_to_fw" {
  count                  = length(var.azs)
  route_table_id         = aws_route_table.tgw[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.fw[count.index].primary_network_interface_id
}

resource "aws_route_table_association" "tgw" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.tgw[count.index].id
  route_table_id = aws_route_table.tgw[count.index].id
}

resource "aws_route_table" "fw" {
  vpc_id = aws_vpc.inspection.id
  tags   = { Name = "${var.project}-inspection-fw" }
}

resource "aws_route" "fw_internet" {
  route_table_id         = aws_route_table.fw.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.inspection.id
}

resource "aws_route" "fw_private" {
  route_table_id         = aws_route_table.fw.id
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = aws_ec2_transit_gateway.tgw.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.inspection]
}

resource "aws_route_table_association" "fw" {
  count          = length(var.azs)
  subnet_id      = aws_subnet.fw[count.index].id
  route_table_id = aws_route_table.fw.id
}

# ==================== Firewall VMs ====================
# Ubuntu + nftables: stateful forwarding, NAT to the internet, MSS clamp toward Azure, and a
# dnsmasq DNS forwarder. Managed through SSM Session Manager: no SSH port, no key pair.

variable "fw_instance_type" {
  description = "Graviton nano: about $0.004/hr. Replaces AWS Network Firewall (~$0.40/hr per AZ) and NAT gateways."
  type        = string
  default     = "t4g.nano"
}

variable "azure_fw_ip" {
  description = "Azure hub firewall IP; the DNS forwarder sends Azure zones there"
  type        = string
  default     = "10.20.241.4"
}

variable "mss_clamp" {
  description = "TCP MSS for flows to/from Azure. IPsec overhead leaves about 1400 bytes of IP MTU."
  type        = number
  default     = 1360
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

resource "aws_iam_role" "fw" {
  name = "${var.project}-fw"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "fw_ssm" {
  role       = aws_iam_role.fw.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "fw" {
  name = "${var.project}-fw"
  role = aws_iam_role.fw.name
}

resource "aws_security_group" "fw" {
  name        = "${var.project}-fw"
  description = "Firewall VMs: anything from private ranges (nftables does the filtering)"
  vpc_id      = aws_vpc.inspection.id

  ingress {
    description = "Private traffic to inspect, and DNS queries"
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

  tags = { Name = "${var.project}-fw" }
}

resource "aws_instance" "fw" {
  count                       = length(var.azs)
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.fw_instance_type
  subnet_id                   = aws_subnet.fw[count.index].id
  private_ip                  = var.fw_ips[count.index]
  vpc_security_group_ids      = [aws_security_group.fw.id]
  associate_public_ip_address = true  # egress NAT; IGW maps it 1:1
  source_dest_check           = false # forwards traffic not addressed to itself
  iam_instance_profile        = aws_iam_instance_profile.fw.name

  user_data = templatefile("${path.module}/fw-cloud-init.yaml.tftpl", {
    fw_ip       = var.fw_ips[count.index]
    vpc_dns     = cidrhost(var.inspection_cidr, 2)
    azure_fw_ip = var.azure_fw_ip
    mss         = var.mss_clamp
  })
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-fw-${substr(var.azs[count.index], -1, 1)}" }

  lifecycle {
    ignore_changes = [ami] # a new Ubuntu build must not replace a running firewall mid-test
  }
}

# ==================== Flow logs ====================
# Inspection VPC: ALL traffic (small, and Test 4 needs the accepted return packets too).
# Spokes log REJECT only (see aws/spoke-app). Stored in S3, not CloudWatch Logs: cheaper per GB.

resource "aws_s3_bucket" "flowlogs" {
  bucket_prefix = "${var.project}-flowlogs-"
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "flowlogs" {
  bucket = aws_s3_bucket.flowlogs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "flowlogs" {
  bucket                  = aws_s3_bucket.flowlogs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_flow_log" "inspection" {
  vpc_id                   = aws_vpc.inspection.id
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = aws_s3_bucket.flowlogs.arn
  max_aggregation_interval = 60
  tags                     = { Name = "${var.project}-inspection" }
}

# ==================== Outputs ====================

output "tgw_id" {
  value = aws_ec2_transit_gateway.tgw.id
}

output "amazon_side_asn" {
  value = var.amazon_side_asn
}

output "tgw_route_table_ids" {
  value = { for k, rt in aws_ec2_transit_gateway_route_table.this : k => rt.id }
}

output "inspection_attachment_id" {
  value = aws_ec2_transit_gateway_vpc_attachment.inspection.id
}

output "inspection_vpc_id" {
  value = aws_vpc.inspection.id
}

output "inspection_cidr" {
  value = var.inspection_cidr
}

output "fw_ips" {
  value = var.fw_ips
}

output "fw_instance_ids" {
  value = aws_instance.fw[*].id
}

output "fw_public_ips" {
  value = aws_instance.fw[*].public_ip
}

output "flowlog_bucket" {
  value = aws_s3_bucket.flowlogs.bucket
}

output "flowlog_bucket_arn" {
  value = aws_s3_bucket.flowlogs.arn
}
