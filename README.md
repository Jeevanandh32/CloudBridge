# CloudBridge

![CloudBridge — multi-cloud failover on AWS and Azure](docs/cover.png)

Multi-cloud AWS + Azure platform built with Terraform — then broken on purpose, measured, and
explained from the routing and DNS layer up. Warm standby: EKS (AWS) primary, AKS (Azure) secondary,
Route 53 health-checked failover, and a separate IPsec/eBGP VPN between the private networks.

## Architecture

![CloudBridge architecture with AWS and Azure service icons](docs/architecture.png)

Users resolve `app.jeevs.click` through Route 53, which sends them to AWS (PRIMARY) or Azure
(SECONDARY) based on a deep `/health` check. The two clouds are also joined privately by two IPsec
tunnels running eBGP — a separate path that failover never depends on.

> **Status (2026-10-18):** all tests complete; every cloud layer has been destroyed. The code rebuilds
> everything in the apply order below (~70 min, the Azure VPN gateway is the slow part).

## Key findings

| What I broke | What I measured | What I learned |
|---|---|---|
| **The backend's DNS record** (repro of the Oct 2025 AWS outage) | Detected ≤ 60 s; clients on Azure 62–145 s; failback **> 3 min → ~70 s** after tuning | **DNS negative caching** (SOA minimum, RFC 2308) made recovery up to 15 min — 10× slower than the outage. Fixed with one SOA record. |
| **The whole AWS app** | Clients on Azure 77–107 s, back in 77–93 s, **0 failed requests on failback** | Detection is fast; the tail is **resolver caching** of the ALB alias's fixed 60 s TTL. |
| **The whole AWS region incl. both VPN tunnels** | Failover unchanged (+102 s); BGP withdrew routes in both clouds; alarms fired and cleared | Failover never depends on the VPN — **separate failure domains**. |
| **An EKS worker node** | User-facing errors **89 s → 57 s (−36%)** with tuned ALB/K8s timers | Kubernetes recovered in 9–30 s; **the load balancer was the bottleneck**. |
| **BGP on the active tunnel** (IPsec up) | **< 1 s** of loss (traffic moved to the other tunnel) | AWS shows the tunnel DOWN when only BGP is down; Azure shows it Connected. |
| **MTU / route propagation / NACL / ALB / pod IPs** | Path MTU 1422, MSS clamped 1310/1360 · green dashboard + blackholed traffic · one-way NACL failure · 502/503/504 decoded · 17 pods per t3.medium | Break/fix lab: each fault hides behind a healthy-looking layer. |

Full numbers: [`docs/results.md`](docs/results.md) · alarms and procedures: [`docs/runbook.md`](docs/runbook.md).

## Services and cost

![CloudBridge services in AWS and Azure](docs/services-dashboard.svg)

Diagrams: `docs/architecture.svg`/`.png` is generated from `docs/architecture.py` (diagrams-as-code);
`docs/services-dashboard.svg` lists every service with its role and running cost.

## Layout

| Path | What it builds | State key |
|---|---|---|
| `terraform/bootstrap` | S3 bucket for remote state (local state, run once) | local |
| `terraform/azure/network` | Resource group, VNet, subnets, **VPN Gateway (slow: 30–45 min)** | `azure/network.tfstate` |
| `terraform/aws/network` | VPC, subnets, single NAT gateway, VGW with route propagation | `aws/network.tfstate` |
| `terraform/connectivity/vpn` | Customer gateway, AWS VPN (2 tunnels), Azure local gateways + connections, BGP | `connectivity/vpn.tfstate` |
| `terraform/aws/eks` | EKS 1.35, 2 × t3.medium managed nodes, VPC CNI | `aws/eks.tfstate` |
| `terraform/azure/aks` | AKS 1.35 free tier, 2 × B2als_v2, Azure CNI with pod subnet | `azure/aks.tfstate` |
| `terraform/global/dns` | Route 53 failover records + health checks (Day 2) | `global/dns.tfstate` |

Each layer is a single `main.tf`, grouped by component: a short **Setup** section (providers,
backend), then one section per component with its variables, resources, and outputs together.
Layers find the state bucket by name (`cloudbridge-tfstate-<aws-account-id>`), so nothing is passed by hand.
See `docs/ip-plan.md` for all address ranges and ASNs, `docs/results.md` for test results,
and `docs/runbook.md` for alarms and failover procedures.

Azure runs in **northcentralus**: the Azure for Students subscription only allows a few regions.

## Prerequisites

- Terraform >= 1.10 (S3 backend native locking), AWS CLI, Azure CLI, kubectl, Helm, Docker
- `aws configure` (IAM admin user with MFA, not root)
- `az login` then `export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)`
- Budget alerts set in both clouds

## Tonight: bootstrap remote state

```bash
cd terraform/bootstrap
terraform init && terraform apply
cp ../backend.hcl.example ../backend.hcl
# put your AWS account ID into the bucket name in ../backend.hcl
```

## Day 1: apply order

Every layer follows the same pattern. `caffeinate -i` keeps a Mac awake during long applies;
if it sleeps, the final state upload to S3 fails.

```bash
cd terraform/<layer>
terraform init -backend-config=../../backend.hcl
terraform plan -out=layer.tfplan
caffeinate -i terraform apply layer.tfplan
```

Order: `azure/network` (start first, the gateway takes 30–45 min) → `aws/network` →
`connectivity/vpn` → `aws/eks` + `azure/aks` → `global/dns`.

## Verify the VPN

```bash
# AWS: both tunnels UP?
aws ec2 describe-vpn-connections \
  --query "VpnConnections[].VgwTelemetry[].{IP:OutsideIpAddress,Status:Status,Routes:AcceptedRouteCount}" \
  --output table

# Azure: BGP peers Connected?
az network vnet-gateway list-bgp-peer-status -g cloudbridge-rg -n cloudbridge-vpngw -o table

# Azure: routes learned from AWS (expect 10.10.0.0/16)
az network vnet-gateway list-learned-routes -g cloudbridge-rg -n cloudbridge-vpngw -o table
```

## Cost control: destroy in reverse order

```bash
# global/dns → aks + eks → vpn → aws/network → azure/network
cd terraform/connectivity/vpn && terraform destroy
cd ../../aws/network          && terraform destroy
cd ../../azure/network        && terraform destroy
# keep bootstrap (the state bucket costs cents)
```

