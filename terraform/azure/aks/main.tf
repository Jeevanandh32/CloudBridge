# AKS: a 1-node Free-tier cluster in the hub-and-spoke network, its image registry,
# and the identity AKS needs to work inside a VNet it doesn't own.
# - Pods: Azure CNI Overlay with Cilium (eBPF data plane + NetworkPolicy for Test 6 Part A).
# - Outbound: userDefinedRouting. The spoke route table sends 0.0.0.0/0 to the hub firewall,
#   so AKS creates no public IP and no outbound public LB (the student quota of 3 public IPs
#   is used by the 2 VPN gateway instances and the firewall).
# - Inbound: internet -> firewall public IP -> DNAT :80 -> AKS internal LB 10.20.4.10 -> pods.

# ==================== Setup ====================

terraform {
  required_version = ">= 1.10"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    # Only used to look up the account ID for the state bucket name
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # State lives in the same S3 bucket as the AWS layers
  backend "s3" {
    key = "azure/aks.tfstate"
  }
}

variable "project" {
  type    = string
  default = "cloudbridge"
}

variable "aws_region" {
  description = "Region of the S3 state bucket"
  type        = string
  default     = "us-east-2"
}

# Subscription comes from ARM_SUBSCRIPTION_ID
provider "azurerm" {
  features {}
  # Providers (Network, Compute, ContainerService, ...) were registered once by hand
  resource_provider_registrations = "none"
}

# Only used to find the state bucket
provider "aws" {
  region = var.aws_region
}

locals {
  tags = { Project = var.project, ManagedBy = "terraform", Layer = "azure-aks" }
}

# ==================== Inputs from the hub and the spoke ====================

# Same naming rule as bootstrap, so nobody has to pass the bucket name in
data "aws_caller_identity" "current" {}

data "terraform_remote_state" "hub" {
  backend = "s3"
  config = {
    bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
    key    = "azure/hub.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "spoke" {
  backend = "s3"
  config = {
    bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
    key    = "azure/spoke-aks.tfstate"
    region = var.aws_region
  }
}

locals {
  hub   = data.terraform_remote_state.hub.outputs
  spoke = data.terraform_remote_state.spoke.outputs
}

# ==================== Variables ====================

variable "admin_cidrs" {
  description = "Public CIDRs allowed to reach the AKS API server (your workstation's IP as x.x.x.x/32). No default on purpose."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "admin_cidrs must be a non-empty list of valid CIDRs, e.g. [\"203.0.113.7/32\"]."
  }
}

variable "kubernetes_version" {
  description = "Same minor version as EKS, so manifests behave the same in both clouds"
  type        = string
  default     = "1.35"
}

variable "node_vm_size" {
  description = "2 vCPU / 4 GB, closest to t3.medium among sizes offered in northcentralus"
  type        = string
  default     = "Standard_B2als_v2"
}

variable "pod_cidr" {
  description = "Overlay pod range. Never leaves the cluster: pods are SNATed to the node IP."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  type    = string
  default = "172.21.0.0/16"
}

variable "dns_service_ip" {
  description = "Must be inside service_cidr"
  type        = string
  default     = "172.21.0.10"
}

variable "ilb_ip" {
  description = "Static IP of the AKS internal LB in the ilb subnet; the hub firewall DNATs port 80 to it"
  type        = string
  default     = "10.20.4.10"
}

# ==================== Control-plane identity ====================

# User-assigned (not system-assigned) so its rights on the spoke can be granted BEFORE the
# cluster exists. AKS checks them during creation: it must join node NICs to aks-nodes, read
# the BYO route table for userDefinedRouting, and later place the internal LB in the ilb subnet.
resource "azurerm_user_assigned_identity" "aks" {
  name                = "${var.project}-aks-control-plane"
  location            = local.hub.location
  resource_group_name = local.hub.resource_group_name
  tags                = local.tags
}

# The VNet scope covers all three spoke subnets (aks-nodes, ilb, pe)
resource "azurerm_role_assignment" "aks_spoke_vnet" {
  scope                = local.spoke.spoke_vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# The route table is a separate resource outside the VNet, so it needs its own grant
resource "azurerm_role_assignment" "aks_route_table" {
  scope                = local.spoke.route_table_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# ==================== AKS cluster ====================

# ---- Egress AKS needs with outboundType = userDefinedRouting ----
# Every node packet to the internet goes spoke UDR -> hub firewall (SNAT to its public IP).
# Today the firewall allows all egress from 10.0.0.0/8, so creation works. Test 6 Part B
# blocks everything and then allows only this list (from Microsoft's "Outbound network and
# FQDN rules for AKS clusters"):
#
#   Required (cluster won't create, register nodes or pull system images without these)
#     *.hcp.northcentralus.azmk8s.io      TCP 443   API server (nodes and konnectivity agent)
#     mcr.microsoft.com                   TCP 443   system images (CoreDNS, Cilium, ...)
#     *.data.mcr.microsoft.com            TCP 443   MCR content (CDN behind mcr)
#     mcr-0001.mcr-msedge.net             TCP 443   MCR content
#     management.azure.com                TCP 443   Azure Resource Manager (LB, routes, disks)
#     login.microsoftonline.com           TCP 443   Entra ID authentication
#     packages.microsoft.com              TCP 443   Microsoft packages (moby, etc.)
#     acs-mirror.azureedge.net            TCP 443   kubelet/kubectl/CNI binaries
#     packages.aks.azure.com              TCP 443   kubelet/CNI binaries (replacing acs-mirror)
#     ntp.ubuntu.com                      UDP 123   time sync (Test 6 records whether nodes
#                                                   fall back to the Hyper-V host clock)
#   Our app
#     <acr name>.azurecr.io               TCP 443   ACR (Basic) registry API
#     *.blob.core.windows.net             TCP 443   ACR Basic layer downloads (no dedicated
#                                                   data endpoints below Premium)
#   Optional (OS security updates; nodes still work without them)
#     security.ubuntu.com, azure.archive.ubuntu.com, changelogs.ubuntu.com  TCP 80
#     snapshot.ubuntu.com                 TCP 443
#
#   Not via the firewall: 168.63.129.16 (Azure DNS/health) and 169.254.169.254 (IMDS) are
#   platform addresses that UDRs don't affect. DNS from the nodes goes to the firewall itself
#   (spoke VNet DNS servers), UDP/TCP 53, inside the VNet.

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "${var.project}-aks"
  location            = local.hub.location
  resource_group_name = local.hub.resource_group_name
  dns_prefix          = "${var.project}-aks"
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Free" # No control-plane SLA; fine for a lab, and $0

  # Free to turn on; lets pods federate to Entra ID (workload identity) later if needed
  oidc_issuer_enabled = true

  default_node_pool {
    name = "system"
    # One node: the student quota is 4 B-series vCPUs and the firewall VM uses 2 of them
    vm_size    = var.node_vm_size
    node_count = 1

    # Nodes get VNet IPs here; pods get overlay IPs from pod_cidr, so no pod subnet
    vnet_subnet_id = local.spoke.subnet_ids["aks-nodes"]

    # Needed if vm_size ever changes (AKS swaps in a temporary pool). Quota warning: the
    # temporary pool's node needs 2 more vCPUs, so stop the firewall VM first or it fails.
    temporary_name_for_rotation = "systemtmp"

    # AKS's own defaults, declared so plans don't show drift. 10% of 1 node rounds up to
    # 1 surge node: 2 + 2 (surge) + 2 (firewall) = 6 vCPU > the 4 quota, so a version
    # upgrade fails on quota. The provider has no max_unavailable yet to upgrade in place;
    # for a lab, destroy and recreate on the new version instead.
    upgrade_settings {
      max_surge                     = "10%"
      drain_timeout_in_minutes      = 0
      node_soak_duration_in_minutes = 0
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium" # Requires network_data_plane = cilium
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    load_balancer_sku   = "standard"
    # No load_balancer_profile: it is only valid with outbound_type = loadBalancer.
    # AKS checks at creation that the node subnet has a route table with 0.0.0.0/0.
    outbound_type = "userDefinedRouting"
  }

  # DNS: no CoreDNS customisation. CoreDNS forwards to the node's resolver, which is the spoke
  # VNet's DNS server = the hub firewall. Its dnsmasq forwards cloudbridge.internal to AWS
  # and everything else to Azure DNS (168.63.129.16), so cross-cloud names already work.

  # Public API endpoint, locked to admin IPs. The firewall's public IP must be on the list
  # too: with userDefinedRouting, nodes reach the API server through the firewall's SNAT,
  # and AKS only auto-allows its own outbound IP when outbound_type is loadBalancer.
  api_server_access_profile {
    authorized_ip_ranges = concat(var.admin_cidrs, ["${local.hub.fw_public_ip}/32"])
  }

  tags = local.tags

  # AKS validates the identity's rights on the subnet and route table during creation
  depends_on = [
    azurerm_role_assignment.aks_spoke_vnet,
    azurerm_role_assignment.aks_route_table,
  ]
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "node_resource_group" {
  description = "Where AKS puts node VMs and the internal load balancer"
  value       = azurerm_kubernetes_cluster.aks.node_resource_group
}

output "kubeconfig_command" {
  value = "az aks get-credentials -g ${local.hub.resource_group_name} -n ${azurerm_kubernetes_cluster.aks.name} --context ${azurerm_kubernetes_cluster.aks.name} --overwrite-existing"
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.aks.oidc_issuer_url
}

# ==================== Internal LB (created by Kubernetes, not Terraform) ====================

# The frontend Service creates the internal LB. These values must match its annotations
# and the firewall's DNAT target; check the manifests against them.
output "ilb_ip" {
  value = var.ilb_ip
}

output "ilb_service_annotations" {
  description = "Annotations the frontend LoadBalancer Service must carry"
  value = {
    "service.beta.kubernetes.io/azure-load-balancer-internal"        = "true"
    "service.beta.kubernetes.io/azure-load-balancer-internal-subnet" = "ilb"
    "service.beta.kubernetes.io/azure-load-balancer-ipv4"            = var.ilb_ip
  }
}

# ==================== ACR image registry ====================

# In-region image registry: AKS never depends on AWS to pull images during a failover
data "azurerm_client_config" "current" {}

resource "azurerm_container_registry" "acr" {
  # Globally unique, letters/digits only: suffix from the subscription ID keeps it stable
  name                = "${var.project}${substr(replace(data.azurerm_client_config.current.subscription_id, "-", ""), 0, 8)}"
  location            = local.hub.location
  resource_group_name = local.hub.resource_group_name
  sku                 = "Basic" # Cheapest tier (~$0.17/day)
  admin_enabled       = false   # Nodes authenticate with their managed identity, not a password
  tags                = local.tags
}

# The kubelet identity (created by AKS in the node resource group) is what nodes use to pull images
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}
