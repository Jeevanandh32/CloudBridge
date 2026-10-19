# CloudBridge test results

Probe: `tests/probe.sh`, 1 request/s to `http://app.jeevs.click/` from a laptop.
Route 53 health checks: HTTP `/health` (deep), 10 s interval, 3 failures.
Records: PRIMARY alias → AWS ALB (TTL 60 s, inherited), SECONDARY → Azure LB (TTL 30 s).
Raw CSVs and break/restore timestamps: `docs/runs/`.

## Test 1 — DNS outage (reproduction of Oct 2025)

Break: delete `backend.cloudbridge.internal` (private zone, CNAME → internal NLB, TTL 30 s).
All pods and load balancers stay healthy; only the dependency's name stops resolving.

| Run | SOA negative TTL | First failure | Route 53 marked AWS unhealthy | Failover seen by client (first 200 from Azure) | Failed requests | Failback after restore |
|---|---|---|---|---|---|---|
| 1 | 900 s (Route 53 default) | 13.9 s | ≤ 32 s | **62.1 s** | 42 / 171 (24.6%) | **> 3 min** (still unhealthy at restore + 149 s; up to 15 min) |
| 2 | 30 s (tuned) | 8.5 s | ≤ 44 s | 98.5 s | 79 / 170 (46.5%) | **68.3 s** |
| 3 | 30 s (tuned) | 16.3 s | ≤ 58 s | 141.5 s | 114 / 171 (66.7%) | **74.0 s** |
| 4 | 30 s (tuned) | 14.7 s | ≤ 69 s | 145.4 s | 119 / 173 (68.8%) | **78.3 s** |
| **Tuned avg (2–4)** | | **13.2 s** | **≤ 57 s** | **128.5 s** | **60.7%** | **73.5 s** |

"Route 53 marked unhealthy" comes from the CloudWatch `HealthCheckStatus` metric (1-minute
resolution, so it's an upper bound). Failed-request % counts the whole 180 s outage window, so it
grows with how long the client keeps the AWS answer.

**Finding (run 1):** failover was fast, failback was not. Deleting the record made resolvers cache
NXDOMAIN for min(SOA TTL 900, SOA minimum 86400) = **15 minutes** (RFC 2308 negative caching), so the
restored record stayed invisible to the AWS frontends. Breaking took ~30 s; recovering took minutes —
the same shape as the real outage, where recovery lagged far behind the fix.

**Change:** private-zone SOA set to TTL 30 / minimum 30 (`terraform/aws/eks`, `aws_route53_record.internal_soa`).
**Trade-off:** shorter negative caching sends more queries to the resolver for names that genuinely
don't exist — negligible for one private zone, which is why it's safe here but not a global default.

**Result (runs 2–4):** failback dropped from > 3 min (up to 15) to **68–78 s**, consistent across
runs: ~30 s negative cache + ~30 s for 3 passing health checks + Azure record TTL.

**Finding: the client's resolver dominates failover time.** Route 53 detected the break within
about a minute every run, but the probe kept reaching AWS for 98–145 s. The probe resolves through
the ISP's (Comcast) resolver farm; the PRIMARY alias inherits the ALB's fixed 60 s TTL, and different
resolver nodes hand out the cached AWS answer at different times. During that window AWS answers
**503** (all frontend pods unready, so the ALB has no healthy targets). Run 1's faster 62 s is the
same mechanism with a luckier cache.

| Phase | Time | Set by |
|---|---|---|
| Frontends unready → ALB 503 | ~13 s | readiness probe (10 s × 3) + CoreDNS/record TTL |
| Route 53 marks AWS unhealthy | ≤ ~60 s | health check 10 s × 3 + checker aggregation |
| Clients switch to Azure | +40–90 s | **resolver caching of the 60 s alias TTL** (not tunable for an ALB alias) |

**Options to cut it further (trade-offs):**
- A CNAME to the ALB with TTL 10–30 s instead of an alias: faster client switch, but loses alias
  benefits (no zone-apex use, CNAME queries are billed) and adds resolver load.
- Return a fast-fail response the client can act on (e.g. client-side retry to a secondary
  hostname) — app change, out of scope.
- The real lesson from Oct 2025: DNS-based failover is bounded by caches you don't control; keep the
  standby warm (it was — zero launches needed) and expect a ~1–2 min tail.

## Test 2 — Region loss (whole AWS app gone)

Break: scale both EKS deployments (frontend, backend) to 0 replicas. The ALB stays up with **no
targets**, so it answers 503 instantly. Restore: scale back to 3 + 3.

| Run | First failure | Route 53 marked AWS unhealthy | Failover seen by client | Failed requests | Failback after restore |
|---|---|---|---|---|---|
| 1 | 1.1 s | ≤ 32 s | 107.4 s | 98 / 168 (58.3%) | 77.0 s |
| 2 | 1.1 s | ≤ 48 s | 77.0 s | 69 / 167 (41.3%) | 85.8 s |
| 3 | 2.0 s | ≤ 63 s | 84.8 s | 76 / 167 (45.5%) | 92.6 s |
| **Avg** | **1.4 s** | **≤ 48 s** | **89.7 s** | **48.4%** | **85.1 s** |

**Compared with Test 1:**
- **Failure starts instantly** (1–2 s vs ~13 s): no readiness probe has to notice anything — the
  pods are simply gone, so the ALB has nothing to send to.
- **Detection is the same** (Route 53 10 s × 3), and **client failover is again dominated by the
  60 s alias TTL** in resolver caches (77–107 s).
- **Failback is slower than Test 1 (85 s vs 74 s)** because pods must be *recreated*: schedule →
  pull image (cached on the node) → start → pass readiness → ALB registers the new pod IPs and they
  pass the ALB health check → Route 53 sees 3 passing checks → client caches expire. Zero failed
  requests during failback: Route 53 only moves traffic back once AWS is fully healthy.

**Static stability check:** Azure needed no scaling, launches, or API calls to take over — its
pods were already running. That's the design lesson from Oct 2025 working as intended.

**Note on "region loss":** this removes the whole AWS application but leaves the region's network
(VPC, VGW, VPN) up, so BGP routes stay advertised. A full regional outage would also drop the
VPN tunnels and withdraw `10.10.0.0/16` from Azure — east-west traffic, not the failover path,
which never depends on the VPN.

## Test 3 — Node failure (terminate one EKS worker), default vs tuned

Probe hits the ALB directly (Route 53 shouldn't fail over: the other node keeps serving). The victim
is the node with the most frontend pods; pods are rebalanced across both nodes before every run.

| Run | Node NotReady | All 6 pods Ready | **Last failed request (user-facing)** | Failed requests | Failure types |
|---|---|---|---|---|---|
| Default (attempt 1)* | 6.6 s | 8.6 s | ≥ 36.8 s (probe stopped too early) | ≥ 10 | 000, 502, 503 |
| **Default** | 2.8 s | 26.2 s | **88.7 s** | 26 / 143 (18.2%) | 000 ×26 |
| Tuned 1 | 2.5 s | 30.4 s | 58.8 s | 18 / 156 (11.5%) | 000 ×16, 502 ×2 |
| Tuned 2 | 3.0 s | 8.8 s | 54.8 s | 18 / 134 (13.4%) | 000 ×17, 502 ×1 |
| **Tuned avg** | 2.8 s | 19.6 s | **56.8 s (−36%)** | **18 (−31%)** | |

\*Attempt 1 stopped probing 30 s after the pods recovered, which revealed that the ALB keeps failing
long after Kubernetes has recovered; the script now probes 150 s past pod recovery.

| Setting | Default | Tuned |
|---|---|---|
| Pod `tolerationSeconds` (not-ready / unreachable) | 300 s | 30 s |
| Readiness probe | 10 s × 3 | 5 s × 2 |
| ALB health check | 15 s interval, 5 s timeout, 2 unhealthy | 5 s, 3 s, 2 |
| ALB deregistration delay | 300 s | 30 s |

**Findings**
1. **Kubernetes wasn't the bottleneck.** Terminating the instance deletes the Node object within
   seconds, so pods reschedule immediately — the 300 s toleration never applies. It only matters
   when a node is NotReady but still exists (network partition, hung kubelet).
2. **Users see the load balancer, not Kubernetes.** Pods were back in 9–30 s, but the ALB kept sending
   some requests to dead pod IPs (`000` = no answer in 2 s) for 55–89 s.
3. **Tuning the ALB timers cut the user-facing tail by 36% and failed requests by 31%.**
4. **Open question:** even tuned, failures continue ~55 s — longer than 5 s × 2 checks + 30 s drain
   explain. Likely contributors: each ALB node health-checks independently, and the controller
   deregisters a target only after the pod object is deleted. Next steps: **pod readiness gates**
   (`elbv2.k8s.aws/pod-readiness-gate-inject`) and **ALB access logs** to attribute each failed request.

**Trade-off of the tuned values:** 5 s × 2 health checks and 30 s tolerations react faster but can
mark a briefly slow pod or node as dead (flapping, needless reschedules); 30 s draining can cut long
requests during deploys. Worth it for a stateless app with short requests; not for long uploads,
WebSockets, or nodes with flaky networking.

## Test 4 — Network break/fix lab

### B1 — BGP down on one tunnel, IPsec up (+ Test 5 / C1 path selection)

**C1 — which tunnel carries traffic** (iperf3 20 Mbit/s × 15 s each way, then byte counters):

| Direction | Tunnel 1 (18.221.20.199) | Tunnel 2 (77.112.118.186) | Source |
|---|---|---|---|
| AWS → Azure | ~0 MB | **39 MB** | Azure connection `ingressBytesTransferred` + AWS `TunnelDataOut` |
| Azure → AWS | 0.2 MB (keepalives) | **39 MB** | AWS `TunnelDataIn` (Azure's `egressBytesTransferred` stayed 0 — not populated) |

Routing is **symmetric** (both directions on tunnel 2); tunnel 1 carries only BGP keepalives. The VGW
doesn't ECMP, and neither managed gateway lets you set AS-path prepending or MED, so path choice
can't be steered from configuration — only by taking a path away.

**B1 — break BGP on the active tunnel** (Azure local network gateway t2: peer ASN 64512 → 65000):

| Measure | Result |
|---|---|
| IPsec (Azure connection status) | **Connected throughout** — only BGP broke |
| BGP peer 169.254.22.1 | `Connecting` → `Idle` → `Connecting` (first seen +95.6 s); never `Connected` while broken |
| **Cross-cloud ping (5/s)** | **9 lost, longest gap 0.8 s** — traffic moved to tunnel 1 |
| Restore (ASN back to 64512) | BGP `Connected` at +113.8 s, **0 pings lost** |
| `terraform plan` afterwards | No changes (restore was complete) |

**Finding:** two tunnels + BGP made losing the active path nearly hitless (< 1 s). The slow part is
*visibility*, not the reroute: Azure took ~1.5 min to show the BGP state (local-gateway update +
BGP timers), and the AWS console reports this tunnel as `DOWN` even though IPsec was up.

### B2 — MTU and MSS across IPsec

| Measure | AWS → Azure | Azure → AWS |
|---|---|---|
| Pod interface MTU (sender) | 9001 (VPC jumbo frames) | 1500 |
| **Path MTU** (largest DF ping + 28) | **1422** | **1420** |
| tracepath | `pmtu 1500` at the VPC router, **`pmtu 1422` at the VGW (169.254.3.1)** | — |
| TCP MSS in the SYN as sent | 8961 | 1460 |
| **TCP MSS as received** | **1310** | **1360** |

**Findings**
- IPsec (ESP + outer IP headers, plus NAT-T) costs ~78 bytes: 1500 → ~1422. EKS pods default to
  **9001**, so anything over ~1422 bytes with DF set dies at the VGW — which reports
  `pmtu 1422` back to tracepath via ICMP "fragmentation needed".
- **TCP is protected by MSS clamping:** the gateways rewrite the MSS in SYN packets, so TCP never
  builds segments that would need fragmenting (both clamped values < path MTU − 40 ≈ 1380). The two
  directions are clamped to different values (1310 vs 1360), which suggests each gateway clamps SYNs
  entering the tunnel on its own side (inference — the managed gateways can't be captured inside).
- **Where it would still break:** UDP or ICMP with DF set, or any path where ICMP "fragmentation
  needed" is filtered (PMTUD black hole) and nothing clamps — e.g. a self-managed router without
  `ip tcp adjust-mss`, or traffic that doesn't pass through these gateways.

### B3 — Route not propagated (tunnels and BGP fine)

| Phase | Private route table | AWS → Azure ping | Tunnels / BGP | Reachability Analyzer |
|---|---|---|---|---|
| Baseline | `10.20.0.0/16 → vgw` (`EnableVgwRoutePropagation`) | 3/3 | UP, 1 route each | — |
| **Propagation disabled** | **no 10.20.0.0/16** → falls to `0.0.0.0/0 → NAT` | **0/3** | **still UP, 1 route each** | **`NO_ROUTE_TO_DESTINATION`** |
| Re-enabled | route back | 3/3 | UP | reachable: **True** |

**Findings:** every VPN indicator stayed green while traffic was blackholed — BGP *learned* the
route, but the VGW was no longer allowed to *install* it in this route table. Azure still had its
route to `10.10.0.0/16`, so the failure was one-directional (requests left Azure, replies had no
path back). Reachability Analyzer found it from configuration alone, without sending a packet
(~$0.10 per analysis).

### B4 — Stateless NACL breaks return traffic

Rule: default NACL (all 4 subnets), **inbound DENY TCP 32768–65535 from 10.20.0.0/16** (the Linux
ephemeral range the EKS pod uses as source ports: 32768–60999).

| Check | Baseline | Rule present | Rule removed |
|---|---|---|---|
| Azure → AWS TCP 9090 (inbound to 9090: not in the denied range) | OK | **OK** | OK |
| AWS → Azure TCP 5201 (replies come back to an ephemeral port) | OK | **blocked — but only ~45% of new connections (9/20 after 30 s; 3/3 in a separate run)** | OK |
| Control: inbound DENY **all** TCP from 10.20.0.0/16 | — | blocked | — |
| ICMP ping | OK | OK (rule is TCP only) | OK |
| Time for an add/remove to take effect | — | first block seen 3–10 s | 1 s |

**Findings**
- **"Works one way only" reproduced:** connections *from* Azure work (their replies leave AWS through
  the egress allow-all rule); connections *to* Azure break, because their replies arrive on ephemeral
  ports that the stateless NACL denies. A **security group** wouldn't do this — SGs are stateful and
  allow replies automatically. Fix: always pair NACL rules with an inbound allow for ephemeral ports.
- **NACL changes aren't instant** (seconds) — tests and runbooks should poll, not sleep a fixed time.
- **Open question:** with the ephemeral-port deny, about half of new connections still succeeded,
  while a deny-all rule blocked everything. Not explained from inside the VPC; next step would be
  VPC Flow Logs (ACCEPT/REJECT per flow) to see which flows bypassed the rule.

### B5 — ALB 502 vs 503 vs 504

Setup (temporary): frontend on image v2 with `ENABLE_FAULTS=true`, ALB idle timeout 5 s.

| Request | Status | Time | `server:` header | Meaning |
|---|---|---|---|---|
| `GET /` | 200 | 0.12 s | `uvicorn` | App answered |
| `GET /slow?s=10` | **504** | **5.13 s** | `awselb/2.0` | Target accepted but didn't answer within the **idle timeout** |
| `GET /crash` | **502** | 0.16 s | `awselb/2.0` | Target **reset the connection** mid-request (process exited; container restarted once) |
| `GET /` with 0 replicas | **503** | 0.14 s | `awselb/2.0` | **No healthy targets** registered |

**How to tell them apart in production:** `server: awselb/2.0` (or ALB access log `elb_status_code` ≠
`target_status_code`) means the ALB generated the error. Response time is the tell for 504 — it
equals the idle timeout. 502 is usually fast. 503 is instant, before any target is touched.

**Operational finding (again):** after the test, removing the `load-balancer-attributes` annotation
left the idle timeout at **5 s** — the controller doesn't reset attributes. The default overlay now
states `idle_timeout.timeout_seconds=60` explicitly (same fix as `deregistration_delay=300` in Test 3).

### B6 — Pod capacity is set by IPs per node, not CPU

| Measure | Value |
|---|---|
| Instance type | t3.medium (2 vCPU, 4 GiB; 3 ENIs × 6 IPv4) |
| **Max pods per node** (kubelet `allocatable.pods`) | **17** = 3 × (6 − 1) + 2 |
| Before: running pods per node | 8 and 9 (system pods + app) |
| Scale backend 3 → 30 | **20 Running, 10 Pending** |
| Running pods per node after | **17 and 17** (full) |
| Pending reason | `0/2 nodes are available: 2 Too many pods` |
| CPU requested on each node | **41–44%** — CPU was nowhere near the limit |

**Findings:** with VPC CNI every pod consumes a VPC IP from the node's ENIs, so the instance type's
ENI/IP limits cap pod density long before CPU or memory. ENIs attach on demand (one node went from 2
to 3 ENIs as pods arrived). Fixes: **prefix delegation** (each ENI slot gets a /28 → ~110 pods on
t3.medium), larger instances, or more nodes. Also watch **subnet** IP exhaustion — that's why the
private subnets are /19.

## Test 5 — Deep experiments

### C1 — Path selection across the two tunnels
Recorded with B1 above: both directions used **tunnel 2**; tunnel 1 carried only BGP keepalives.
Managed gateways expose no AS-path/MED controls, so the only lever is removing a path (B1), which
moved traffic to tunnel 1 in < 1 s.

### C2 — Full AWS region loss: app **and** VPN down

Break: EKS app scaled to 0 **and** a wrong pre-shared key on both Azure connections (IKE fails →
both tunnels down). Fix: `terraform apply` in `connectivity/vpn` — the runbook's drift step
(plan showed `shared_key` changes on both connections, values hidden as sensitive).

| Time after break | AWS tunnels | Azure BGP | Azure routes to AWS | AWS route to Azure | Alarms (degraded / down) |
|---|---|---|---|---|---|
| −30 s | UP / UP | Connected ×2 | 2 | present | OK / OK |
| **+101.6 s** | | | | | users served by **Azure** |
| +131 s | DOWN / UP | Connecting ×2 | **0 (withdrawn)** | **gone** | **ALARM** / OK |
| +177 s | DOWN / DOWN | Connecting ×2 | 0 | gone | ALARM / OK |
| +452 s | DOWN / DOWN | Connecting ×2 | 0 | gone | ALARM / **ALARM** |
| PSK fixed + 30 s | **UP / UP** | **Connected ×2** | 2 | present | **OK / OK** |
| App scaled up + 77.2 s | | | | | users back on **AWS**, 0 failed during failback |

**Findings**
- **Failover never depended on the VPN:** clients reached Azure at +102 s — same as Test 2 (app-only
  loss, 77–107 s) — with both tunnels down. Separate failure domains, proven.
- **BGP cleaned up both clouds automatically:** each side withdrew the other's /16 once the sessions
  dropped; AWS traffic to `10.20.x` then falls to `0.0.0.0/0 → NAT` and is dropped (fails closed).
- **Alarms fired in order of severity:** degraded (one tunnel) ~2 min, down (both) ~7.5 min — the
  5-minute metric period is the floor for VPN alarms. They cleared on their own after recovery.
- **The runbook worked:** `terraform plan` named the exact drift; `apply` restored both tunnels,
  BGP, and routes within ~30 s of finishing.
