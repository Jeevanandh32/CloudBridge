# CloudBridge plan

> **Status: carried out (2026-11-23).** All 6 tests ran across 3 sessions, and every layer was
> destroyed afterwards. This page is the plan as written beforehand. Measured results are in the
> [README](../README.md#results) and [`docs/runs/`](runs/). Where reality differed from the
> plan, the run summaries say so. For example:
> - Test 4's appliance-mode break had no effect on VPN traffic; switching it back on caused the
>   drops instead.
> - Test 5's prefix delegation stalled on /28 fragmentation.
> - Traffic Manager needed DNS-name endpoints.
>
> Cost came to about $0.80/hr while running and about $7 in total.

v1 proved that active-passive failover across AWS and Azure works. This plan rebuilds the
network the way an enterprise would run it, keeps Kubernetes, and cuts the tests down to
6 that are about networking:

- **AWS:** a hub-and-spoke network around a Transit Gateway.
- **Azure:** a hub VNet with a peered spoke.
- **Kubernetes:** EKS and AKS stay, with the tests moved to cluster networking.
- **DNS:** served by two providers, so Route 53 is no longer a single point of failure.

Every service was chosen against the test that needs it, at the lowest cost that still
shows the production pattern.

## Decisions

| Area | Decision |
|---|---|
| v1 tests and results | Archived in `docs/archive/v1/`, linked once from the README |
| Repo | Same repo; v1 tagged `v1` |
| AKS pod networking | Azure CNI Overlay with Cilium |
| EKS NetworkPolicy | Built into the VPC CNI |
| EKS nodes | Spot |
| VPN | Active-active: 2 Azure gateway instances, 2 AWS VPN connections, 4 tunnels |
| Firewall | Ubuntu + nftables VM (routing, NAT, DNS forwarding) |
| Second DNS provider | Azure DNS + Traffic Manager |
| Budget | $25 total, alarm at $15 |
| Session length | 5+ hours (3 tests per session) |
| Afterwards | Update README, video, resume and LinkedIn |

## Limits that shape the design

The Azure for Students subscription in `northcentralus` allows **6 vCPU total, 4 vCPU of
B-series, and 3 public IPs**. Only AMD Basv2 sizes are offered.

- **Azure public IPs: exactly 3, no headroom.**
  - 2 are for the active-active VPN gateway.
  - 1 is for the firewall, which handles all inbound and outbound traffic.
  - AKS uses no public IP of its own: outbound goes through the firewall, inbound is DNAT
    on the firewall to an internal load balancer.
- **Azure B-series vCPU: 4 used out of 4.**
  - AKS runs 1 node (`Standard_B2als_v2`, 2 vCPU).
  - The firewall takes the other 2 (`Standard_B2ats_v2`).
  - One AKS node is enough now that the node-failure test is cut.
- **AWS:** no quota problems at these sizes.

## Architecture

```
                              Users
                                │
        app.jeevs.click: name servers from Route 53 AND Azure DNS
          Route 53 failover records      Azure DNS CNAME -> Traffic Manager (priority)
                  │                                     │
┌──────────── AWS us-east-2 (active) ─────────┐  ┌──── Azure northcentralus (passive) ────┐
│                                              │  │                                        │
│  App spoke VPC            Inspection VPC     │  │  Hub VNet                              │
│  ┌────────────────┐       ┌──────────────┐   │  │  ┌──────────────────────────────────┐  │
│  │ ALB (public)   │       │ fw-a  fw-b   │   │  │  │ VPN gateway, active-active (2 IPs)│  │
│  │ EKS (Spot)     │       │ nftables+NAT │   │  │  │ fw VM: nftables, NAT, DNAT, DNS   │  │
│  │ S3 endpoints   │       │ DNS forwarder│   │  │  └───────────────┬──────────────────┘  │
│  └───────┬────────┘       └──────┬───────┘   │  │                  │ peering             │
│          │      Transit Gateway  │           │  │  Spoke VNet      │                     │
│          └──────────┬────────────┘           │  │  ┌───────────────┴──────────────────┐  │
│                     │ 2 VPN attachments,     │  │  │ AKS (Overlay + Cilium), internal  │  │
│                     │ ECMP                   │  │  │ LB, Storage Private Endpoint      │  │
│                     │                        │  │  └───────────────────────────────────┘  │
└─────────────────────┼────────────────────────┘  └───────────────────┬─────────────────────┘
                      └───────── 4 IPsec tunnels, eBGP 64512 <-> 65515 ┘
```

**Traffic paths:**
- **Inbound, AWS:** internet → ALB (app spoke) → EKS pods. Inbound stays local to the
  spoke, and only outbound is centralized, which is the common AWS pattern.
- **Outbound, AWS:** EKS nodes → Transit Gateway → firewall (NAT) → internet.
- **Between clouds:** Azure → VPN → Transit Gateway → firewall → app spoke, and the same
  path in reverse. Everything is inspected.
- **Inbound, Azure:** internet → firewall public IP (DNAT) → AKS internal LB → pods.
- **Outbound, Azure:** AKS (UDR 0.0.0.0/0) → hub firewall (SNAT) → internet.

## IP plan

Nothing overlaps, so any range can be routed across the VPN.

### AWS (aggregate 10.10.0.0/16)

| Range | Use |
|---|---|
| `10.10.0.0/20` | **App spoke VPC** (primary CIDR) |
| `10.10.0.0/26`, `10.10.0.64/26` | EKS node subnets, 2a / 2b; pods use them too by default. **Kept small on purpose for Test 5.** Test hosts at `10.10.0.10` and `10.10.0.74`. |
| `10.10.4.0/24`, `10.10.5.0/24` | Public subnets for the ALB, 2a / 2b |
| `10.10.15.0/28`, `10.10.15.16/28` | Transit Gateway attachment subnets |
| `10.10.64.0/18` | **App spoke secondary CIDR**, added during Test 5 as the fix: pod subnets `10.10.64.0/19` and `10.10.96.0/19` (custom networking) |
| `10.10.240.0/24` | **Inspection VPC** |
| `10.10.240.0/28`, `.16/28` | Transit Gateway attachment subnets, 2a / 2b |
| `10.10.240.32/28`, `.48/28` | Public firewall subnets, 2a / 2b: fw-a `10.10.240.40`, fw-b `10.10.240.56`. Each firewall has one NIC and its own public IP for egress NAT. |
| `172.20.0.0/16` | EKS service CIDR (never routed) |

### Azure (aggregate 10.20.0.0/16)

| Range | Use |
|---|---|
| `10.20.240.0/22` | **Hub VNet** |
| `10.20.240.0/27` | `GatewaySubnet` |
| `10.20.241.0/28` | Firewall subnet (inside interface) |
| `10.20.241.16/28` | Firewall subnet (outside interface, public IP) |
| `10.20.0.0/20` | **Spoke VNet** |
| `10.20.0.0/22` | AKS node subnet |
| `10.20.4.0/27` | Internal LB subnet |
| `10.20.5.0/27` | Private Endpoint subnet |
| `10.244.0.0/16` | AKS overlay pod CIDR. Never leaves the cluster: pods are SNATed to the node IP. |
| `172.21.0.0/16` | AKS service CIDR, DNS `172.21.0.10` |

### BGP and tunnels

| Item | Value |
|---|---|
| Transit Gateway ASN | `64512` (ECMP for VPN enabled) |
| Azure VPN gateway ASN | `65515` |
| VPN connection c0 → Azure instance 0 | tunnels `169.254.21.0/30`, `169.254.22.0/30` (AWS `.1`, Azure `.2`) |
| VPN connection c1 → Azure instance 1 | tunnels `169.254.21.4/30`, `169.254.22.4/30` (AWS `.5`, Azure `.6`) |

Azure only accepts custom APIPA BGP addresses in `169.254.21.0–169.254.22.255`, which is
why all four tunnels sit in those two blocks.

**Routes each side should learn:**
- **Azure learns** `10.10.0.0/20`, `10.10.240.0/24`, and `10.10.64.0/18` once added,
  each over all 4 tunnels.
- **The Transit Gateway learns** `10.20.240.0/22` and `10.20.0.0/20`. The overlay pod CIDR
  is never advertised.

## Services and cost

Prices are approximate (us-east-2 / northcentralus). They get checked in the AWS and
Azure pricing calculators before the first build.

| Service | Why it's here | Cheaper choice made | ≈ $/hr |
|---|---|---|---|
| EKS control plane | Tests 5 and 6 | — | 0.10 |
| EKS nodes, 2 × t3.medium Spot | Pods and NetworkPolicy | Spot instead of on-demand | 0.03 |
| Transit Gateway, 4 attachments | Hub and spoke, Test 4 | Only 2 VPCs, not 3+ | 0.20 |
| 2 AWS VPN connections | Active-active, Test 3 | — | 0.10 |
| ALB | AWS inbound and health checks | — | 0.03 |
| 2 firewall VMs (t4g.nano), each with a public IP | Inspection, NAT, DNS | Instead of AWS Network Firewall (~0.40) and NAT gateways | 0.02 |
| 2 test hosts (t4g.nano), Session 1 only | Something for Tests 3 and 4 to reach before the clusters exist | — | 0.01 |
| S3 gateway + interface endpoint (1 AZ) | Private access | Gateway endpoint is free; 1 AZ only | 0.01 |
| AWS public IPv4 (ALB, EIP) | — | Kept to a minimum | 0.02 |
| Azure VPN gateway VpnGw1AZ, active-active | Test 3 | Active-active costs no extra for the gateway itself | 0.19–0.36* |
| AKS, Free tier, 1 × B2als_v2 | Tests 5 and 6 | Free control plane | 0.04 |
| Azure firewall VM (B2ats_v2) | Inspection, NAT, DNAT, DNS | Instead of Azure Firewall (~0.40–1.25) and NAT Gateway | 0.02 |
| Azure public IPs × 3 | VPN ×2, firewall | AKS has none | 0.02 |
| Private Endpoint (Storage) | Private access | 1 endpoint | 0.01 |
| Route 53 + Azure DNS zones, Traffic Manager | Test 1 | — | ≈ $1.50/month |
| Flow logs, rejected flows only, to S3 / Storage | Test 4 | Not CloudWatch Logs, not all flows | pennies |

\* The VpnGw1AZ price is confirmed in the calculator before the build.

**Total running: about $0.80–1.00/hr.** For comparison, the same design built with managed
firewalls, NAT gateways and Route 53 / Azure DNS Private Resolvers would be about
$2.50–3.00/hr.

**Production upgrade points to document:**
- **Firewall:** move to AWS Network Firewall or Azure Firewall above about 1 Gbps, or when
  compliance needs managed IDS.
- **Private DNS:** move to managed resolver endpoints when more than one VPC or VNet needs
  hybrid DNS.

### Budget

| Item | Value |
|---|---|
| Total | $25 (AWS budget $15, alerts at $9 / $15; Azure budget $10, alerts at $6 / $10) |
| Planned spend | 4 sessions × 5 h ≈ $16–19, plus about $2 of fixed DNS and storage |
| Rule | Destroy every layer at the end of each session and confirm with the inventory check |

## Terraform layers

Each layer is a separate root with its own state in the existing S3 backend. Each test
applies only the layers it needs.

| # | Layer | Contents | Build time |
|---|---|---|---|
| 1 | `azure/hub` | RG, hub VNet, active-active VpnGw1AZ (2 public IPs), firewall VM with IP forwarding, private DNS zone `az.cloudbridge.internal`, Storage account, VNet flow logs | **30–45 min** (the gateway) |
| 2 | `aws/hub` | Transit Gateway (ECMP, default route tables off), inspection VPC, fw-a / fw-b, EIP, TGW route tables, flow logs → S3 | 5 min |
| 3 | `aws/spoke-app` | App VPC, subnets, TGW attachment, ALB subnets, S3 gateway + interface endpoint, private zone `cloudbridge.internal` | 3 min |
| 4 | `azure/spoke-aks` | Spoke VNet, peering (gateway transit), UDRs, internal LB subnet, Private Endpoint | 2 min |
| 5 | `connectivity/vpn` | 2 customer gateways, 2 VPN connections on the TGW, 4 local network gateways, 4 connections, BGP | 10 min |
| 6 | `aws/eks` | EKS (public API restricted to your IP), Spot node group, VPC CNI with NetworkPolicy, LB controller | 15 min |
| 7 | `azure/aks` | AKS Free tier, Overlay + Cilium, `outboundType: userDefinedRouting`, internal LB | 10 min |
| 8 | `global/dns` | Route 53 failover records + health checks, Azure DNS zone + Traffic Manager, registrar name servers set to both providers | 2 min |
| 9 | `ops` | Budgets, alarms (tunnel state, health checks), dashboard | 1 min |

**Private API endpoints are left out on purpose.** A private-only EKS or AKS API needs a
jump box to run Terraform and kubectl, which adds cost and complexity. A public API locked
to your IP is the cost-optimized choice for the lab, and the README documents this.

## The 6 tests

Each test has one break, one measurement, and one line to say in an interview.

### Test 1: DNS failover with no single point of failure
- **Part A (rerun of v1 T1):** the app's dependency DNS record disappears. Measure
  failover time with the default SOA negative TTL, then with the tuned one.
- **Part B (new):** on the test client, run a local recursive resolver (unbound, cache
  off) and block every Route 53 name server IP with `pf`. Then trigger failover.
- **Expected result:**
  - The resolver retries against the Azure DNS name servers.
  - Each query takes longer (a timeout plus a retry); measure how much.
  - `app.jeevs.click` still resolves, and still fails over through Traffic Manager.
- **Say:** "I cut failover time by fixing negative caching, then proved users still reach
  the app with Route 53 completely gone."

### Test 2: Region loss (rerun of v1 C2, which included T2)
- **Break:**
  - Scale every EKS pod to 0.
  - Break both AWS VPN connections at once: wrong PSK, so all 4 tunnels go down.
- **Expected result:**
  - Route 53 and Traffic Manager both move users to Azure. Measure the downtime.
  - BGP withdraws all routes on both sides.
  - The tunnel alarms fire.
  - Restore is timed separately.
- **Say:** "The DNS failover path never depends on the VPN, so losing the region and the
  private link together still fails over cleanly."

### Test 3: Hybrid routing failover
- **Measure:**
  - Path selection: are flows spread by ECMP over all 4 tunnels? Read per-tunnel byte
    counters on both sides.
  - Break BGP on the busiest tunnel while IPsec stays up, with a 5/s ping running. Time
    the reroute.
  - Then take down one whole Azure gateway instance (2 tunnels) and time it again.
  - MTU / MSS: path MTU each way, and the MSS clamp on the firewalls.
- **Expected result:**
  - The reroute takes about the BGP hold time (Azure's default is 30–90 s).
  - Losing one Azure instance costs half the tunnels, with no outage.
- **Say:** "I killed a tunnel, then a whole gateway; BGP and ECMP kept traffic flowing,
  and I fixed the MTU drops tunnels cause."

### Test 4: Hub-and-spoke routing through the firewall
- **Break A, a TGW route table mistake:**
  - The mistake: remove the inspection VPC's route back to the VPN attachment, or
    propagate the spoke into the wrong table.
  - Expected: Azure → app traffic blackholes.
  - Find it: TGW route tables, Reachability Analyzer, flow logs.
- **Break B, appliance mode off:**
  - The setup: flows that cross AZs come back through a different firewall.
  - Expected: nftables drops them as invalid state (`fw-invalid` counters). Flow logs show
    each request on one firewall's NIC and its reply on the other's. They log as ACCEPT,
    because the security group allows them: the drop happens inside the firewall, which is
    exactly why it's hard to spot.
  - Fix: turn on TGW appliance mode.
- **Say:** "I broke the hub routing, then used flow logs to find the asymmetric path
  through the stateful firewall that was dropping return traffic."

### Test 5: Pod networking across clouds
- **Break:**
  - Scale an EKS deployment until pods stay Pending.
  - First the per-node ENI limit is hit. Fix it with prefix delegation.
  - Then the small pod subnets run out. Fix it with the secondary CIDR `10.10.64.0/18`
    and custom networking.
- **Cross-cloud check:**
  - An AKS pod calls an EKS pod directly by pod IP; this works because EKS pods have
    routable VPC IPs.
  - An EKS pod calls an AKS pod, which can't be reached because Overlay pod IPs are not
    routable. It has to go through the internal LB.
  - Use tcpdump to see which source IP arrives in each direction: the AKS pod shows up as
    its node IP after SNAT.
- **Say:** "I ran out of pod IPs twice for two different reasons, fixed the IP plan, and
  showed why routable and overlay pod networks behave differently across a VPN."

### Test 6: Kubernetes traffic control
- **Part A, NetworkPolicy:**
  - Apply default-deny in both clusters, then allow only frontend → backend and DNS.
  - Prove that blocked flows fail and are logged (Cilium on AKS, VPC CNI policy logs on
    EKS).
- **Part B, forced egress:**
  - All AKS and EKS outbound traffic goes through the firewalls.
  - Block everything first and record what breaks: image pulls, node registration, time
    sync.
  - Then allow only the FQDNs each cluster needs.
  - Show the inbound asymmetric-routing problem that public LBs cause on AKS with a
    0.0.0.0/0 UDR, and why DNAT on the firewall fixes it.
- **Say:** "Pods only talk where policy allows, and every byte leaving the clusters goes
  through a firewall I control."

**Built in and checked once, not tested separately:**
- **Private DNS across clouds:**
  - **AWS → Azure names:** EKS CoreDNS forwards `az.cloudbridge.internal` and
    `privatelink.blob.core.windows.net` to the AWS firewalls' forwarders, which pass them on
    to the Azure firewall.
  - **Azure side:** the Azure spoke VNet's DNS server *is* the hub firewall (the hub DNS
    pattern). Every AKS lookup goes through its dnsmasq, which forwards `cloudbridge.internal`
    to AWS. The same path lets Test 6 build an FQDN egress allowlist.
  - **The trade-off:** the Azure firewall VM is also AKS's DNS, so the what-if report counts
    one more flow that depends on it.
- **Private access:**
  - An EKS pod reads the Azure Storage account through its Private Endpoint.
  - An AKS pod reads S3 through the interface endpoint, over the VPN.

## MindBridge AI

A Python tool on the laptop (`tools/mindbridge/`). It does not add cloud services or tests. It
runs during the same 6 tests, so its claims are measured.

| Job | What it does | Input |
|---|---|---|
| **Prevent** | What-if sweep: removes each component in turn and works out which flows break, for how long, and whether recovery is automatic or manual. Pre-change check: maps a `terraform plan` onto the model and blocks changes that would break a flow. | Terraform code and plans, `tools/mindbridge/design.yaml` |
| **Predict** | Watches warning signs and warns before impact: free subnet IPs, conntrack and NAT port use, per-tunnel loss and latency, BGP flaps and IKE rekey failures, Spot rebalance notices, health-check latency, quota headroom, expiry dates, budget burn | Read-only CLI and API polling every minute, stored locally |
| **Diagnose** | When something breaks, gathers evidence with read-only tools and proposes the root cause and a fix | Same read-only tools |

**Design rules:**
- Deterministic code does the reachability, failover and trend maths. The AI explains and
  correlates the results, and may only quote numbers from them.
- MindBridge AI never changes anything. Every fix goes through Terraform, and you approve it.
- Only the topology and metric data is sent to the API: no account IDs, keys or secrets.

**How it is proven:**
- Before each injected failure in Tests 2–6, MindBridge records a prediction. The results get
  "predicted vs measured" columns.
- Three slow-burn failures measure how much warning it gives and how many false alarms it
  raises:
  - pod IP exhaustion (Session 2);
  - tunnel degradation (Session 1);
  - conntrack filling up (Session 1).

**Cost:** $0 extra in the cloud, and a few cents of API calls per session.

## Session plan (5+ hours each)

| Session | Layers up | Tests | ≈ Cost |
|---|---|---|---|
| 1 | 1–5, 9 (no clusters) | Test 3, Test 4 | $3.50 |
| 2 | 1–7, 9 | Test 5, Test 6 | $4.50 |
| 3 | 1–9 | Test 1, Test 2, plus README screenshots and data | $4.50 |
| 4 | as needed | Reruns, video capture | $4.50 |

In every session, start applying `azure/hub` first: the VPN gateway takes the longest, and
the other layers build while it does.

## Repo changes

1. Tag the current `main` as `v1`.
2. Move v1 tests, analysers and results into `docs/archive/v1/` and `tests/archive/v1/`.
3. Replace the Terraform roots with the 9 layers above.
4. Write new test scripts `tests/test1…test6`, plus an inventory check script that lists
   anything still running in either cloud.
5. The README shows only the current tests and results, with a short archived v1 section.
