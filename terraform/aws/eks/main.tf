# EKS: the cluster and Spot node group in the app spoke, the VPC CNI add-on with
# NetworkPolicy and the Test 5 pod-IP switches, the Load Balancer Controller's IAM role, and
# the image registry. The private zone cloudbridge.internal now lives in aws/spoke-app.

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

data "terraform_remote_state" "spoke" {
  backend = "s3"
  config = {
    bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
    key    = "aws/spoke-app.tfstate"
    region = var.region
  }
}

variable "azure_cidr" {
  description = "Azure aggregate (hub + spoke VNets). Fixed by the IP plan, so no Azure state is read"
  type        = string
  default     = "10.20.0.0/16"
}

locals {
  spoke = data.terraform_remote_state.spoke.outputs

  # Nodes go in the first two node subnets: 2a and 2b
  node_subnet_ids = slice(local.spoke.node_subnet_ids, 0, 2)
}

output "vpc_id" {
  description = "Needed by the AWS Load Balancer Controller Helm install"
  value       = local.spoke.vpc_id
}

# ==================== EKS cluster ====================

variable "cluster_name" {
  description = "Must match cluster_name in aws/spoke-app (used in subnet discovery tags)"
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

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint (your laptop's public IP as /32). No default on purpose"
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrnetmask(c))])
    error_message = "admin_cidrs needs at least one valid IPv4 CIDR, e.g. [\"203.0.113.7/32\"]."
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  # Public endpoint locked to admin_cidrs so kubectl and Terraform work from the laptop without
  # a jump box. Nodes use the private endpoint: with the VPC's default DNS (AmazonProvidedDNS)
  # the API hostname resolves to the private ENIs from inside the VPC, so node and pod traffic
  # to the API never leaves the VPC (and never touches the firewalls).
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.admin_cidrs
  endpoint_private_access      = true

  # The IAM identity running Terraform becomes cluster admin
  enable_cluster_creator_admin_permissions = true

  # Control-plane ENIs also land in the /26 node subnets: they count against Test 5's IP budget
  vpc_id            = local.spoke.vpc_id
  subnet_ids        = local.node_subnet_ids
  service_ipv4_cidr = var.service_cidr

  # Cost: no KMS key and no control-plane logs in CloudWatch for a short-lived lab
  encryption_config           = null
  create_kms_key              = false
  enabled_log_types           = []
  create_cloudwatch_log_group = false

  # vpc-cni is managed below, outside the module, so node groups can be ordered after it
  # (see "VPC CNI add-on"). Pod identity agent is for the AWS Load Balancer Controller.
  addons = {
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    # Cross-cloud DNS lives in the add-on's own config, so add-on updates keep it.
    # Forwards az.cloudbridge.internal and the blob zones to the AWS firewalls' dnsmasq.
    coredns = {
      configuration_values = file("${path.module}/../../../k8s/coredns-eks/addon-configuration.json")
    }
  }

  eks_managed_node_groups = {
    spot = {
      ami_type       = "AL2023_x86_64_STANDARD"
      capacity_type  = "SPOT"
      instance_types = var.node_instance_types # Same ENI/IP limits, so max-pods is the same
      subnet_ids     = local.node_subnet_ids

      # Fixed size: no autoscaling. max_size has one spare so a rolling update can surge
      min_size     = var.node_count
      max_size     = var.node_count + 1
      desired_size = var.node_count
      update_config = {
        max_unavailable = 1
      }

      # No AMI ID is set, so EKS generates the nodeadm NodeConfig itself and injects maxPods,
      # calculated from the VPC CNI settings at the moment the nodes launch. Changing the CNI
      # add-on alone never touches running nodes. These launch template tags change whenever
      # the CNI config changes -> new launch template version -> managed rolling replacement,
      # and the new nodes get the new maxPods. Referencing the add-on also makes Terraform
      # finish updating the add-on before the node group update starts.
      launch_template_tags = {
        "cloudbridge:pod-ip-mode"    = local.pod_ip_mode
        "cloudbridge:vpc-cni-config" = substr(sha1(aws_eks_addon.vpc_cni.configuration_values), 0, 12)
      }

      # Visible in `kubectl get nodes -L cloudbridge.io/pod-ip-mode`
      labels = {
        "cloudbridge.io/pod-ip-mode" = local.pod_ip_mode
      }
    }
  }

  # No NAT here: node egress goes to the TGW and through the inspection firewalls.
  # Azure reaches pods directly (pods have routable VPC IPs). The VPC CIDR rule covers the
  # ALB in IP-target mode and pods in the secondary CIDR. With custom networking the pod ENIs
  # use this same security group (it goes into the ENIConfigs), so these rules cover pods too.
  # One rule per VPC CIDR. A single rule holding a list of CIDRs is replaced when a CIDR is
  # added, and AWS rejects the new rule as a duplicate of the old one (Session 2, when the
  # secondary CIDR was added). Separate rules mean adding a CIDR just adds a rule.
  node_security_group_additional_rules = merge(
    {
      azure = {
        description = "All traffic from Azure over the VPN (via the firewalls)"
        protocol    = "-1"
        from_port   = 0
        to_port     = 0
        type        = "ingress"
        cidr_blocks = [var.azure_cidr]
      }
    },
    {
      for cidr in local.spoke.vpc_cidrs : "vpc-${replace(replace(cidr, ".", "-"), "/", "_")}" => {
        description = "All traffic from app spoke VPC CIDR ${cidr}"
        protocol    = "-1"
        from_port   = 0
        to_port     = 0
        type        = "ingress"
        cidr_blocks = [cidr]
      }
    }
  )
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "node_security_group_id" {
  description = "Also the pod security group for the ENIConfigs (custom networking)"
  value       = module.eks.node_security_group_id
}

output "cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name} --region ${var.region}"
}

# ==================== Node group sizing ====================

variable "node_instance_types" {
  description = "Spot pool. Both have 3 ENIs x 6 IPv4 each, so max-pods is the same for either"
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]
}

variable "node_count" {
  type    = number
  default = 2
}

# ==================== VPC CNI add-on ====================

variable "enable_prefix_delegation" {
  description = "Test 5 fix 1: each ENI slot holds a /28 prefix (16 IPs) instead of 1 IP. Rolls the nodes"
  type        = bool
  default     = false
}

variable "enable_custom_networking" {
  description = "Test 5 fix 2: pods get IPs from the secondary-CIDR pod subnets via ENIConfigs. Needs aws/spoke-app enable_secondary_cidr = true and the ENIConfigs applied first. Rolls the nodes"
  type        = bool
  default     = false
}

locals {
  pod_ip_mode = join("-", compact([
    var.enable_prefix_delegation ? "prefix" : "secondary-ip",
    var.enable_custom_networking ? "custom-net" : "",
  ]))

  vpc_cni_env = merge(
    {
      # By default the CNI SNATs pod traffic to the node IP for anything outside the VPC
      # CIDRs. Azure is outside them, so without this AKS would see node IPs, not pod IPs.
      # Excluding 10.20.0.0/16 keeps the pod's own VPC IP on the way to Azure: the
      # "routable pods" half of Test 5 (AKS -> EKS pod IP works; tcpdump shows real pod IPs).
      # Internet traffic is still SNATed to the node IP, then NATed again by the firewalls.
      AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS = var.azure_cidr

      ENABLE_PREFIX_DELEGATION           = tostring(var.enable_prefix_delegation)
      AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = tostring(var.enable_custom_networking)
    },
    # Keep one spare /28 per node, not a whole spare ENI's worth of prefixes
    var.enable_prefix_delegation ? { WARM_PREFIX_TARGET = "1" } : {},
    # Each node picks the ENIConfig named after its AZ (us-east-2a / us-east-2b)
    var.enable_custom_networking ? { ENI_CONFIG_LABEL_DEF = "topology.kubernetes.io/zone" } : {},
  )
}

data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "vpc-cni"
  addon_version               = data.aws_eks_addon_version.vpc_cni.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    env = local.vpc_cni_env

    # EKS's built-in NetworkPolicy enforcement (eBPF network policy agent on each node).
    # Policy event logs (Test 6 part A) go to /var/log/aws-routed-eni/network-policy-agent.log
    # on the node; CloudWatch shipping stays off for cost.
    enableNetworkPolicy = "true"
    nodeAgent = {
      enablePolicyEventLogs = "true"
    }
  })

  lifecycle {
    precondition {
      condition     = !var.enable_custom_networking || length(local.spoke.pod_subnet_ids) > 0
      error_message = "enable_custom_networking needs pod subnets: apply aws/spoke-app with enable_secondary_cidr = true first."
    }
  }
}

# ENIConfigs are not created here (kubernetes_manifest needs a live cluster at plan time).
# k8s/eniconfig/ builds them from these outputs: one ENIConfig per AZ, named after the AZ.
# Order for Test 5 fix 2: spoke-app enable_secondary_cidr=true -> apply this layer (outputs
# fill in) -> apply the ENIConfigs -> set enable_custom_networking=true and apply (nodes roll).
data "aws_subnet" "pod" {
  count = length(local.spoke.pod_subnet_ids)
  id    = local.spoke.pod_subnet_ids[count.index]
}

output "eniconfig_subnets" {
  description = "AZ -> pod subnet id for the ENIConfigs. Empty until aws/spoke-app enable_secondary_cidr = true"
  value       = { for s in data.aws_subnet.pod : s.availability_zone => s.id }
}

# Per-node ENI math for t3.medium / t3a.medium: 3 ENIs, 6 IPv4 per ENI (1 is the ENI's own).
#   secondary IPs:             3 x (6-1)      + 2 = 17
#   prefix delegation:         3 x (6-1) x 16 + 2 = 242 -> capped at 110 by managed node groups
#   custom networking only:    2 x (6-1)      + 2 = 12  (primary ENI carries no pods)
#   custom networking + prefix 2 x (6-1) x 16 + 2 = 162 -> capped at 110
locals {
  max_pods = {
    "secondary-ip"            = 17
    "prefix"                  = 110
    "secondary-ip-custom-net" = 12
    "prefix-custom-net"       = 110
  }
}

output "max_pods_note" {
  value = join(" ", [
    "Mode ${local.pod_ip_mode}: expect ${local.max_pods[local.pod_ip_mode]} pods per node",
    "(check: kubectl get nodes -o custom-columns=NAME:.metadata.name,PODS:.status.capacity.pods).",
    "EKS sets maxPods only when a node launches; changing the CNI mode rolls the Spot node group via a new launch template version.",
    "Prefix mode needs free contiguous /28 blocks: each /26 node subnet has 4 aligned /28s, but the first and last contain AWS-reserved IPs, so at most 2 can ever be delegated, and node IPs fragment those (Test 5 second break: rollout failed with 34-49 IPs free).",
  ])
}

# ==================== ECR image registry ====================

# In-region image registry: EKS never depends on another cloud to pull images.
# Nodes can already pull from it (the module attaches AmazonEC2ContainerRegistryReadOnly).
# Pulls go out through the firewalls (ECR API/DKR); layers come from S3 via the gateway endpoint.
resource "aws_ecr_repository" "app" {
  name                 = "${var.project}-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # Lets `terraform destroy` remove it even with images inside
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

# ==================== AWS Load Balancer Controller IAM (Pod Identity) ====================

# IAM role for the AWS Load Balancer Controller (installed with Helm), handed out through EKS
# Pod Identity: only the controller's service account can assume it, not every pod on the
# node. It builds the internet-facing ALB in the public subnets (tagged kubernetes.io/role/elb).
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
