# CloudBridge IP plan

Rule: nothing below overlaps, so any range can be routed across the VPN later.

## AWS — us-east-2 (deliberately not us-east-1)

| Range | Use | Notes |
|---|---|---|
| `10.10.0.0/16` | VPC | |
| `10.10.0.0/19` | Private subnet, us-east-2a | EKS nodes **and pods** (VPC CNI gives pods VPC IPs) |
| `10.10.32.0/19` | Private subnet, us-east-2b | EKS nodes and pods |
| `10.10.64.0/24` | Public subnet, us-east-2a | NAT gateway, public ALB |
| `10.10.65.0/24` | Public subnet, us-east-2b | Public ALB |
| `10.10.128.0/17` | Reserved | Future secondary pod ranges, test VMs |
| `172.20.0.0/16` | EKS service CIDR | Cluster-internal only, never routed |

## Azure — northcentralus

The Azure for Students subscription has a policy that allows only `northcentralus`, `westus`,
`francecentral`, `norwayeast` and `mexicocentral`. `northcentralus` (Chicago) is the closest to
AWS us-east-2. It has no availability zones, so the VpnGw1AZ gateway runs regional there.

| Range | Use | Notes |
|---|---|---|
| `10.20.0.0/16` | VNet | |
| `10.20.0.0/22` | `aks-nodes` subnet | AKS node IPs |
| `10.20.32.0/19` | `aks-pods` subnet | Azure CNI pod IPs (routable across VPN) |
| `10.20.64.0/24` | `test` subnet | Test VM for cross-cloud ping |
| `10.20.255.0/27` | `GatewaySubnet` | Name is required by Azure; /27 or larger |
| `172.21.0.0/16` | AKS service CIDR | DNS service IP `172.21.0.10` |

## BGP and tunnels

| Item | Value |
|---|---|
| AWS VGW ASN | `64512` |
| Azure VPN Gateway ASN | `65515` |
| Tunnel 1 inside CIDR | `169.254.21.0/30` — AWS `.1`, Azure `.2` |
| Tunnel 2 inside CIDR | `169.254.22.0/30` — AWS `.1`, Azure `.2` |
| Azure APIPA BGP addresses | `169.254.21.2`, `169.254.22.2` |
| IKE version | IKEv2 |

Azure allows custom APIPA BGP addresses only in `169.254.21.0 – 169.254.22.255`,
which is why the tunnels use those two /30s.

## Expected routes after the VPN is up

- Azure learns `10.10.0.0/16` from both AWS tunnels.
- AWS private route tables learn `10.20.0.0/16` via VGW propagation.

## Pod and node addressing (observed)

| Cluster | Nodes | Pods | Services (never routed) |
|---|---|---|---|
| EKS | private subnets `10.10.0.0/19`, `10.10.32.0/19` | same subnets (VPC CNI) | `172.20.0.0/16` |
| AKS | `aks-nodes` `10.20.0.0/22` | `aks-pods` `10.20.32.0/19` (Azure CNI pod subnet) | `172.21.0.0/16`, DNS `172.21.0.10` |

## Public endpoints and DNS names

| Name | Points to | Notes |
|---|---|---|
| `app.jeevs.click` PRIMARY | Alias → public ALB (AWS LB Controller) | TTL 60 s (alias inherits the ALB's TTL) |
| `app.jeevs.click` SECONDARY | Azure frontend public IP (static, from `terraform/azure/aks`) | TTL 30 s |
| `backend.cloudbridge.internal` | CNAME → internal NLB (private zone, VPC only) | TTL 30 s; Test 1 deletes it |

Azure public IPs (subscription limit 3): VPN gateway, AKS outbound LB, frontend LB.
The VPN gateway's IP changes on every rebuild; the VPN layer reads it from state.
