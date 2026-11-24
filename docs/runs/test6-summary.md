# Test 6: Kubernetes traffic control (Session 2, 2026-11-23)

## Part A: NetworkPolicy (default-deny, then allow only the app's flows)

**14 of 14 checks** matched (7 flows × 2 clusters):

| Flow | Before | After |
|---|---|---|
| frontend → backend:8080 | allowed | **allowed** |
| probe pod → backend:8080 | allowed | **blocked** |
| probe DNS (CoreDNS) | allowed | **allowed** |
| probe → internet https | allowed | **blocked** |
| backend → frontend:80 | allowed | **blocked** |
| frontend → internet https | allowed | **blocked** |
| internet → LB → frontend /health | allowed | **allowed** |

**Where the denied flows showed up:**
- **EKS** (VPC CNI policy engine): DENY verdicts in the node's network-policy-agent log, 20
  lines across the 2 nodes. **VPC flow logs do not show these drops**: they happen in eBPF on
  the node, after the security group has already accepted the packet.
- **AKS** (Cilium): the blocks held, but `cilium-dbg monitor --type drop` caught 0 events in its
  45 s window. Hubble isn't available without Advanced Container Networking Services.

## Part B: egress through the firewalls

### Azure: FQDN allowlist on the hub firewall (dnsmasq nftset fills the allowed-IP set)

| Step | MCR image pull | Docker Hub pull | AKS node |
|---|---|---|---|
| Allow-all | ✅ | ✅ | Ready |
| **Block all egress** | ❌ | ❌ | kubelet: `Error updating node status`, it can't reach its own API server |
| **FQDN allowlist** (AKS required FQDNs + ACR + blob + NTP; 23 IPs learned via DNS) | ✅ | ❌ (not listed) | Ready. Pod from ACR runs; pod from Docker Hub is in `ImagePullBackOff` |
| Restored | ✅ | ✅ | Ready |

### AWS: port-based control on fw-a / fw-b (only TCP 443 and UDP 123 from EKS subnets)

| Destination | Allow-all | Port-based |
|---|---|---|
| https://example.com | ✅ | ✅ |
| **https://wikipedia.org (any site)** | ✅ | ✅ **still open** |
| http://example.com (80) | ✅ | ❌ |
| ICMP | ✅ | ❌ |
| NTP | ✅ | ✅ |
| EKS itself (image pulls, DNS, API) | ✅ | ✅ nothing broke |

**What the two egress tests show:**
- **Port rules aren't egress control.** They stop plain HTTP and ICMP, but anything on 443 still
  gets out. Domain-level control needs FQDN or SNI filtering (AWS Network Firewall) or interface
  endpoints. The Azure FQDN allowlist blocked Docker Hub on 443.
- **EKS needed nothing extra opened.** DNS uses the VPC resolver and time uses the Amazon Time
  Sync Service, so neither crosses the firewall. The API uses its private endpoint, and image
  layers come through the S3 gateway endpoint.

## Part C: inbound path to AKS through the firewall

- **First attempt failed.** Internet → firewall public IP → DNAT → ILB 10.20.4.10 timed out,
  even though the firewall itself could reach the ILB.
- **Root cause.**
  - The AKS internal LB rule has **floating IP off**, so Azure rewrites the destination to the
    node IP.
  - The AKS node NSG only allows `VirtualNetwork` and `AzureLoadBalancer` sources, and the
    DNAT kept the client's internet IP, so the SYN was dropped before the node.
  - Adding `loadBalancerSourceRanges` didn't help: AKS put the allow rule on the ILB IP, which
    never matches after the rewrite.
- **Fix: SNAT inbound DNAT traffic on the firewall**, which is what Azure Firewall does for DNAT.
  - It works because the node then sees a VNet source.
  - It also guarantees the reply returns through the firewall.
  - Trade-off: the app sees the firewall's IP instead of the client's.
  - Applied live, added to the cloud-init template, and the firewall VM now ignores
    custom_data changes so a template edit can't replace it mid-session.
- **Verified.** Conntrack shows `[ASSURED]` flows with the reply addressed to the firewall
  (`dst=10.20.241.4`): symmetric through one stateful device.

Raw data: `test6-policy.txt`, `test6-egress-azure*.txt`, `test6-egress-aws*.txt`, `test6-inbound-asym.txt`.
