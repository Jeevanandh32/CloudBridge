# MindBridge

MindBridge finds single points of failure in the CloudBridge network design, checks
Terraform plans before they are applied (**prevent**), and watches warning signs so it can warn
before a failure happens (**predict**, see [Predict mode](#predict-mode)).

Deterministic Python does all of the reachability, failover, trend and forecast maths. The AI
explainer is optional: it only rewords and correlates the deterministic results, and it is
checked so that it quotes no numbers the results don't contain.

The model was calibrated against Session 1 and Session 2 (both 2026-11-23): see
[Session 1 calibration](#session-1-calibration) and
[Session 2 calibration](#session-2-calibration) for what it predicted, what was measured, and
what changed.

## Setup

```bash
python3 -m venv /path/outside/the/repo/mbvenv
/path/outside/the/repo/mbvenv/bin/pip install -r tools/mindbridge/requirements.txt pytest
cd tools
```

## Commands

Run these from `tools/`:

```bash
python -m mindbridge whatif                 # N-1 sweep -> docs/mindbridge/whatif-report.{md,json}
python -m mindbridge precheck plan.json     # exit 2 if a flow with weight >= 5 would degrade or break
python -m mindbridge explain                # optional; needs ANTHROPIC_API_KEY, else skips
python -m mindbridge facts                  # what the builder read from the Terraform
python -m mindbridge watch [--interval 60] [--once] [--only aws_vpn,azure_firewall] [-v]
python -m mindbridge predict [--since 30m]  # -> docs/mindbridge/alerts-<timestamp>.{md,json}
python -m mindbridge replay <series.csv>... # lead time and false alarms, offline
python -m pytest mindbridge/tests -q
```

To precheck a real change, make the plan yourself and convert it to JSON. This reads a local
file only, and MindBridge never runs Terraform:

```bash
terraform plan -out tfplan && terraform show -json tfplan > plan.json
python -m mindbridge precheck plan.json [--layer aws/hub] [--threshold 5] [--json]
```

If you leave out `--layer`, MindBridge infers it from the resource addresses in the plan.

## How it works

| File | Role |
|---|---|
| `design.yaml` | The topology model. **Components** have an id, cloud, layer (the Terraform root, `planned` or `external`) and their Terraform addresses, plus optional BGP `failure_modes`, a `redundancy_window` and a `transition_risk`. **Hops** have members and a mode: `failover`, `pinned` or `single`. **Flows** are weighted business paths with an optional `path` kind (`vpn-vpc`, `vpc-vpc`). The file also holds the recovery times (measured values carry `source: measured 2026-11-23`), the measured firewall `capacity`, and the **fixes** catalogue. |
| `builder.py` | Parses the current Terraform roots with python-hcl2 and resolves simple `var.x` defaults. It reads facts such as the firewall count, the `tgw_to_fw` route target, `active_active`, the VPN connection and tunnel counts, the Test 4 toggles and quota usage. It changes the model where the code decides, and it lists every fact it could not resolve. |
| `model.py` | The evaluator. A hop loses `dead/total` of its traffic. A `failover` hop recovers automatically after `recovery_s`; the BGP tunnel hop does so per **failure mode** (below). A `pinned` hop stays broken until a manual fix. A `single` hop breaks completely, or by its `loss_impact`, which can depend on the flow's `path` (`loss_impact_by_path`). Flow impact is `1 - product(1 - hop impact)`. A failover flow (users -> app) switches to its standby path through the DNS health-check hop. A failover hop that runs on fewer members also records the share lost and the **reduced-redundancy window**. |
| `whatif.py` | Removes each component in turn and scores the result: `severity = flow weight x impact x recovery penalty + reduced-redundancy penalty`. The recovery penalty is 10 for manual recovery, 4 for provider recovery, and 1 + s/60 (capped at 5) for automatic recovery. The reduced-redundancy penalty is weight x share lost x min(3, window s / 600). Components that can fail in more than one BGP mode are evaluated once per mode; both are reported, labelled, and the row is scored on the worse. Results are ranked worst first, in three sections (infrastructure, config, management), plus a table of change (transition) risks. |
| `precheck.py` + `rules.yaml` | Maps `resource_changes` (delete, replace, or an update of a named attribute) onto the components a change takes out. It evaluates two cases: while the apply runs and after the apply. A rule can say whether its BGP loss is `clean` or `silent`; the verdict uses that mode and both are printed. **Transition rules** block any change to an attribute that is disruptive to change on live traffic (appliance mode), and **convergence** notes flag TGW route-table changes. **Node-roll** checks report EKS node group, launch template and VPC CNI config changes, and block prefix delegation in the node subnets. **Hazards** block plan shapes AWS rejects at apply time (a multi-CIDR security-group rule replace). |
| `explain.py` | The optional explainer, using the Anthropic SDK. It sends only the report rows, the flows, the constraints, the fixes and the component list, never Terraform, facts, IDs or tfvars. When an `alerts-*.json` exists in `docs/mindbridge/` (or `--alerts` names one), it also sends the alerts with their evidence values and impact, and asks for a "Warnings now" section that correlates them. `--no-alerts` leaves them out. The model defaults to `claude-opus-5-5` and can be changed with `MINDBRIDGE_MODEL`. |
| `collect.py` | Predict mode: the registry of read-only collectors. |
| `store.py` | Predict mode: the SQLite sample store, outside the repo. |
| `detect.py` | Predict mode: the detectors, as pure functions. |
| `predict.py` | Predict mode: runs the detectors, attaches the what-if impact, writes the alert files and runs `replay`. |

Components in the planned roots (`aws/eks`, `azure/aks`, `global/dns`) come from
`docs/plan.md`. The report flags them as "planned, not yet in code". The v1
versions of those roots are not parsed.

### BGP failure modes, reduced redundancy, transitions

- **Clean withdrawal** (`bgp_clean_withdrawal_s` = 0 s): a config mismatch, an admin shutdown,
  a peer NOTIFICATION, or a VPN connection replaced or deleted through the API. The routes are
  withdrawn at once and ECMP rehashes the flows. Measured: 0 of 16 flows lost a packet. The
  flows don't degrade; they only lose redundancy.
- **Silent failure** (`bgp_silent_s` = 30 s): a gateway instance reboot or crash. Nothing tells
  the peer, so the flows hashed onto the lost tunnels wait for the BGP hold timer. Measured:
  6 of 16 flows (38 %) had a 22-31 s gap when 2 of 4 tunnels went. The model uses the tunnel
  share (50 %) for that case.
- Tunnels and VPN connections can fail either way, so what-if shows both. A gateway instance
  can only fail silently. A TGW propagation removal is clean. When the cause isn't known, the
  model assumes silent.
- **Reduced-redundancy window**: the time a component stays degraded after users have
  recovered. Measured for an Azure gateway instance: 14 min 20 s (`azure_gw_instance_rebuild_s`
  = 860 s) to rebuild its tunnels and BGP. What-if reports it as "users recover in ~30 s;
  redundancy is reduced for ~14 min", and adds it to the severity. Precheck doesn't use the
  rebuild time, because a planned change stays until the apply ends or someone reverts it.
- **Appliance mode** is scoped to VPC<->VPC flows between AZ-pinned attachments (50 %,
  estimate). For VPN<->VPC flows (every current flow), the measured impact of turning it off is
  0: all 400 flows were symmetric. Changing `appliance_mode_support` in either direction is a
  **transition risk**: about 14 min of asymmetric drops (22-40 % success) were measured when it
  was re-enabled. Precheck blocks any change to it with a "maintenance window" message.
- **Route-change convergence** (`tgw_route_convergence_s` = 5 s): TGW route-table changes take
  a few seconds to apply. Precheck notes it for every TGW propagation, route and association
  change (14-20 % still got through just after a break; 87-95 % right after a restore).

## Precheck fixtures

The fixtures are in `tests/fixtures/`, and each one is a hand-written plan in the
`terraform show -json` format.

| Fixture | Change | Verdict |
|---|---|---|
| `break-a-propagation.json` | `app_to_inspection` propagation deleted (Test 4 break A) | block: azure-to-aws broken, plus a convergence note |
| `break-a-restore.json` | The propagation created again (Test 4 restore A) | pass, with a convergence note (a few seconds of mixed results) |
| `break-b-appliance-mode.json` | `appliance_mode_support` enable -> disable (Test 4 break B) | block: transition risk (maintenance window). The end state costs VPN<->VPC flows nothing |
| `appliance-mode-enable.json` | `appliance_mode_support` disable -> enable (Test 4 restore B) | block: transition risk, ~14 min of drops measured |
| `fw-a-replace.json` | fw-a replaced, route repointed | block: 50% down until the apply ends |
| `fw-both-replace-userdata.json` | Cloud-init edit replaces both firewalls | block: every inspected flow is down during the apply |
| `vpn-c0-replace.json` | VPN connection c0 replaced (new IPs and PSKs) | pass: a clean withdrawal, so no packet loss; redundancy is 2 of 4 tunnels until the apply ends. The silent case (50% for ~30 s) is printed alongside |
| `active-active-false.json` | Azure gateway `active_active` set to false | block: silent failure, degraded 50% for ~30 s, and redundancy halved for good |
| `safe-tags-only.json` | Tag change only | pass |
| `s3-endpoint-replace.json` | S3 interface endpoint replaced | pass (only a weight-2 flow is hit) |
| `prefix-only.json` | VPC CNI add-on `ENABLE_PREFIX_DELEGATION` false -> true, custom networking off; the launch template and node group follow (Session 2 step 2) | block: node roll, plus prefix delegation in the /26 node subnets (check free aligned /28s first) |
| `prefix-custom.json` | Prefix delegation stays on, custom networking turned on (Session 2 step 3) | pass: node roll, with a warning to check the ENIConfigs and the pod subnets' free aligned /28s |
| `sg-rule-multi-cidr.json` | `aws_security_group_rule.node["vpc"]` replaced: `cidr_blocks` keeps 10.10.0.0/20 and adds 10.10.64.0/18 | block: AWS rejects the new rule as a duplicate (`InvalidPermission.Duplicate`) |

**Node rolls (EKS).** Any update or replace of an `aws_eks_node_group` or its
`aws_launch_template`, or a change to the VPC CNI add-on's `configuration_values`, is reported
as a node roll: all nodes replaced one at a time; workloads move; a drain can stall. A roll is
not a block on its own. The pod-IP mode before and after is read from the add-on's
`configuration_values` (`ENABLE_PREFIX_DELEGATION`, `AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG`), or
else from the node group label `cloudbridge.io/pod-ip-mode` or the launch template tag. When
the change moves pods onto prefix delegation, or changes where the /28s come from, with prefix
delegation on afterwards:
- **custom networking off:** BLOCK. Pods take /28s from the node subnets; check free aligned
  /28s first.
- **custom networking on:** warning only. The /28s come from the pod subnets in the ENIConfigs.

The builder still treats `aws/eks` as a planned root, so these plans print "layer could not be
inferred"; the node-roll and hazard checks don't need the layer.

## Limits

- It is N-1 only. The two DNS health-check systems never show up alone, because each one
  matters only after the AWS path has failed.
- Some numbers are still estimates, flagged `estimate: true` in `design.yaml` or marked
  "estimate": the DNS provider retry (3 s), the dnsmasq retry (5 s), the appliance-mode loss for
  VPC<->VPC flows (about 50 %; it needs a second spoke VPC to measure), and the firewall
  packet-rate limits (`fw_pps_limit`). Test 1 measured the DNS values.
- The silent-failure impact is the tunnel share (50 % for 2 of 4). ECMP hashing of 16 probe
  flows gave 38 %; with more flows the share converges on the tunnel share.
- Values that come through `terraform_remote_state` can't be read offline, so they are
  assumed and listed under "Could not resolve" in the report.

## Predict mode

Predict mode polls read-only signals, stores them locally, and runs deterministic detectors that
warn before a component reaches its failure point. Each alert carries the evidence samples, an
ETA or a deviation, and an **impact** worked out by the what-if model: "if this component fails,
which flows break, and how long does recovery take".

```
collect.py (read-only CLIs) -> store.py (SQLite) -> detect.py (pure maths) -> predict.py (+ what-if impact) -> alerts-<ts>.md/.json
                                                                                                    \-> explain.py (optional AI wording)
```

The rule from v1 still holds. Deterministic code detects and forecasts; the AI only explains and
correlates the alerts, and may only quote the numbers they contain.

### Commands

```bash
python -m mindbridge watch --once -v      # every collector once, print the samples and any alerts
python -m mindbridge watch                # loop: 60 s tick, each collector at its own interval
python -m mindbridge predict --since 2h   # detectors over the store, write docs/mindbridge/alerts-<ts>.{md,json}
python -m mindbridge replay mindbridge/tests/fixtures/series/*.csv   # offline scoring
python -m mindbridge explain              # includes the newest alerts-*.json if there is one
```

- **Store:** `~/.mindbridge/signals.db` by default, or set `MINDBRIDGE_DB`. MindBridge refuses a
  path inside the repo. Samples are `(ts, signal, component, value, unit, detail)`. A re-sent
  CloudWatch datapoint with the same timestamp is stored once.
- **`--since`:** the window for fast signals (default 30m). A signal whose detector needs a
  longer window keeps that window: the budget trend uses 7 days and the baselines use 6 hours.
- **`replay` exit codes:** 3 if a marked failure was not predicted or a false alarm fired,
  otherwise 0.

### Collectors and signals

A collector whose CLI is missing, whose target isn't deployed, or that runs out of time is
recorded as `unavailable` with a reason, and the others carry on. Targets, intervals and
timeouts are in `design.yaml` under `signals:`.

| Collector (interval) | Command (read-only) | Signals | Detector | Maps to |
|---|---|---|---|---|
| `aws_subnets` (1 min) | `aws ec2 describe-subnets`, tag `Project=cloudbridge`; one `aws ec2 describe-network-interfaces --filters Name=subnet-id,...` for the node and pod subnets (`aligned28_subnets`) | `subnet.free_ips`, `subnet.free_aligned_28` | time-to-threshold → 0; for `free_aligned_28` only while the cluster has nodes in the prefix mode that draws from that subnet | pod/node subnet 2a/2b → `eks-node-a/b`; fw subnets → `fw-a/b`; TGW subnets → attachments |
| `aws_vpn` (1 min) | `aws ec2 describe-vpn-connections` with a narrow `--query` (outside IP, status, accepted routes, inside CIDR) | `vpn.tunnel_up`, `vpn.accepted_routes` | flap counter (4 changes / 30 min) | inside CIDR → `vpn-c0-t1` … `vpn-c1-t2` |
| `aws_vpn_cloudwatch` (5 min) | one `aws cloudwatch get-metric-data` call: 4 tunnels × TunnelState (Minimum), TunnelDataIn/Out (Sum), period 300 s | `vpn.cw_tunnel_state`, `vpn.cw_data_in/out` | flap counter (state); bytes are context only (ECMP share) | tunnel |
| `azure_vpngw` (2 min) | `az network vnet-gateway list-bgp-peer-status`, `list-learned-routes` | `azure.bgp_peer_up`, `azure.bgp_routes_received`, `azure.learned_routes` | flap counter | BGP neighbor → tunnel |
| `aws_firewalls` (5 min) | `aws ssm send-command` AWS-RunShellScript on fw-a/fw-b; `get-command-invocation` | `fw.conntrack_pct` (+ count, max), `fw.nat_ports_pct` (+ SNAT entries), `fw.nft_drop_total`, `fw.nft_invalid_total`, `fw.cpu_pct` (+ steal), `fw.pps`, `fw.load1` | time-to-threshold → 90 % (conntrack, NAT), → 85 % (CPU), → `fw_pps_limit` (packet rate); EWMA baseline on drop/invalid per-minute rates | `fw-a`, `fw-b` |
| `azure_firewall` (2 min) | One `az vm run-command invoke` on cloudbridge-fw: the same counters, plus a fine loss probe, `ping -c 200 -i 0.2 -q` (40 s, 0.5 % resolution) to each **present** probe target in parallel, 2 rounds back to back. Targets (`path_probe_targets`) are resolved first: test hosts by EC2 Name tag (`describe-instances`), EKS frontend pods per AZ (`kubectl get pods`), or a LoadBalancer Service IP | as above, plus `path.loss_pct`, `path.rtt_ms` per target (`az-fw-><name>`, IP in the detail), one sample per minute | as above; loss trend → 5 % on the fine data, EWMA baseline on loss and RTT | `az-fw`; a path → the 4 tunnels + the target's AZ firewall (+ its EKS node) (candidates) |
| `kubernetes` (1 min) | `kubectl --context cloudbridge-eks/aks get pods (Pending) / nodes / events (Warning)` | `k8s.pending_pods` (with reasons), `k8s.node_bad_conditions` (NotReady, pressure, cordoned), `k8s.sandbox_failures`, `k8s.ip_assign_errors`, `k8s.spot_events`, `k8s.pod_ip_mode` (nodes per `cloudbridge.io/pod-ip-mode` label value, component `<cluster>:<mode>`) | sustained level (k of n); `pod_ip_mode` has no detector, it gates `subnet.free_aligned_28` | node zone → `eks-node-a/b`, `aks-node`; cluster → its nodes (candidates) |
| `aws_spot` (2 min) | `aws autoscaling describe-scaling-activities` for ASGs tagged `eks:cluster-name=cloudbridge-eks` | `aws.spot_rebalance` (rebalance or interruption replacements, last 15 min) | level > 0 | EKS nodes (candidates) |
| `azure_quotas` (1 h) | `az network list-usages`, `az vm list-usage` (northcentralus) | `quota.azure_public_ips`, `quota.azure_cores`, `quota.azure_bs_vcpu`, `quota.azure_basv2_vcpu` (+ `.limit`) | quota headroom | none: lists the fixes the quota blocks |
| `domain` (6 h) | `aws route53domains get-domain-detail --region us-east-1` with `--query` for the expiry and auto-renew only (no contact data) | `domain.expiry_days`, `domain.auto_renew` | countdown (warn 30 d, critical 7 d); auto-renew must be 0 | `registrar` |
| `budgets` (1 h) | `aws budgets describe-budget` (`cloudbridge-aws`), `az consumption budget show` (`cloudbridge-azure`) | `budget.actual_usd`, `budget.forecast_usd`, `budget.limit_usd` | burn-rate projection to the limit (linear fit over 7 d); forecast above the limit | none (session stop) |

**Free aligned /28s (prefix delegation):**
- **Why:** with prefix delegation each ENI slot takes an aligned /28 (16 contiguous addresses
  on a /28 boundary). Scattered secondary IPs and ENI primaries fragment a small subnet, so it
  can show plenty of free IPs and still have no whole /28. Session 2 hit exactly this in the
  /26 node subnets.
- **How:** every private IP and `Ipv4Prefix` of every ENI in the subnet, plus the 5
  AWS-reserved addresses (the first 4 and the last), mark their /28 as used. The sample is the
  count of /28-aligned blocks left completely free, with "N of M aligned /28s free; F free
  IPs" in the detail. A /26 has 4 aligned /28s, but the first and last hold reserved addresses,
  so at most 2 can ever be delegated. A /19 pod subnet has 512 (510 usable).
- **When it applies:** the detector is gated on the node label `cloudbridge.io/pod-ip-mode`:
  node subnets while nodes are in `prefix` mode, pod subnets while they are in
  `prefix-custom-net`. With no recent mode sample (15 min) the gate is closed. In secondary-IP
  mode the count means nothing, so it stays quiet.
- **Not counted:** subnet CIDR reservations (`get-subnet-cidr-reservations`) are not read.

**Path-probe targets follow the topology:** the ping destinations come from
`signals.targets.path_probe_targets` in `design.yaml`, and each is looked up before the probe
runs: an EC2 test host by its Name tag (and expected IP), an EKS pod by context, namespace,
selector and the AZ's CIDRs (Running and Ready), or a LoadBalancer Service's ingress IP. A
target that can't be resolved or found is skipped, recorded as `probe <name>: unavailable:
target absent (...)` (collector status `partial`), and gives no loss samples. With no target
present the script runs the counters only. `resolve: static` is never checked; avoid it.

**Firewall details:**
- **Conntrack:** `conntrack -C`, or `/proc/sys/net/netfilter/nf_conntrack_count` if that fails,
  against `nf_conntrack_max`. The count (entries in use) and the max (table size) are separate
  signals per component, and a count above the max is reported as a labelling problem, never
  turned into a percentage. The real `nf_conntrack_max` on the t4g.nano firewalls is
  1,048,576, and Session 1's peak was about 8,600 entries. The 7,168 in the recorded data was
  an Azure-firewall count, not a max.
- **CPU and packet rate:** two counter snapshots, `/proc/stat` (CPU jiffies) and
  `/proc/net/dev` (rx + tx packets, every interface except `lo`), taken in the same script. On
  the AWS firewalls they are 10 s apart (`fw_sample_s`); on the Azure firewall they bracket the
  ~80 s ping rounds. They give `fw.cpu_pct`, `fw.cpu_steal_pct` and `fw.pps`, with nothing
  kept between runs. On these small VMs, CPU and packet rate are the binding limits, not the
  state table: filling 1,048,576 entries would take about 35,000 new flows/s per firewall.
- **NAT ports:** `conntrack -L -n` (SNAT entries), grouped by original destination ip:port.
  The busiest destination is divided by 64,512, the masquerade source-port range (1024–65535).
  Port exhaustion happens per destination tuple, so this is the number that matters; the total
  SNAT count is stored as context.
- **Drops:** the `fw-drop` and `fw-invalid` counters in `nft list chain inet fw forward`.

**One Run Command per VM, one combined script:** Azure Run Command takes 20–40 s and holds one
lock per VM. So the counters and the loss probe share one invocation (2 x 40 s probe rounds,
~80 s script, 100–120 s with overhead) every 120 s. That gives one loss sample per destination
per minute without two invocations ever queueing on the lock. Because `watch` runs collectors
one after another, run this collector in its own process (`watch --only azure_firewall`, same
`MINDBRIDGE_DB`) so it doesn't hold up the 1-minute collectors.

**What changes, and what never does:**
- **SSM `send-command`:** runs a script that only reads counters. It changes nothing on the
  instance, but SSM keeps a **command-invocation record** (Run Command history, 30 days), and
  CloudTrail logs the call.
- **`az vm run-command invoke`:** the same, and it shows in the Activity Log. Run Command runs one
  command at a time, so if a test script is using it at the same moment, one of the two waits.
- **No PSKs:** `describe-vpn-connections` returns the tunnels' pre-shared keys. Every call uses a
  narrow `--query`, so they are never printed, parsed or stored.
- **No account ID stored:** the AWS budget call needs the account ID. It is read with
  `sts get-caller-identity` and kept in memory only.
- **Scrubbed errors:** error text has account IDs, GUIDs, ARNs and emails removed before it is
  stored or printed.

**Tunnel path quality and ECMP:**
- **One tunnel per ping:** the ping is one ICMP flow, so it hashes onto one of the 4 tunnels (the
  Azure gateway picks the tunnel outbound, the TGW picks it on the way back). Loss and RTT are
  therefore recorded **per destination**, not per tunnel.
- **Unknown tunnel:** the alert's impact lists every tunnel and the host's AZ firewall as
  candidates, and shows the worst case.
- **Tunnels the ping doesn't use:** a bad tunnel that none of the pings hash onto is invisible to
  this signal. Its flap and BGP signals still see it.
- **Loss resolution:** 200 pings per sample resolve loss in 0.5 % steps. Session 1's probe
  (20 pings every 5 min) only saw 5 % steps, and its samples read `0, 5, 0, 5, 10, 5, 15` while
  real loss rose from 0 to 5 %. That was too coarse and too few points for any trend.

**What EKS managed node groups emit for Spot:**
- **Capacity Rebalancing is on:** managed node groups turn it on for Spot, so when EC2 sends a
  rebalance recommendation, the ASG launches a replacement. EKS then cordons and drains the old
  node.
- **What Kubernetes sees:** the node goes `unschedulable` (kubelet event `NodeNotSchedulable`),
  its pods are evicted, and later the node reports `NodeNotReady` and is removed.
- **No Spot events:** there are no Kubernetes events with reasons like `SpotInterruption` or
  `RebalanceRecommendation`. Only AWS Node Termination Handler or Karpenter emits those, and
  CloudBridge installs neither.
- **The 2-minute interruption notice:** it reaches only EventBridge and the instance metadata
  service.

So MindBridge watches three things: the ASG's scaling activities (`aws.spot_rebalance`), cordoned
nodes (counted in `k8s.node_bad_conditions`), and the Spot reasons in case a handler is ever
added. Confirm the exact event reasons in Session 2.

### Detectors (`detect.py`)

All are pure functions over one `(signal, component)` series, and all are unit-tested.

| Detector | Method | Fires when |
|---|---|---|
| `time_to_threshold` | Least-squares line over a sliding window (any detector can sit behind a `gate`: it runs only while a gating series, e.g. `k8s.pod_ip_mode`, is > 0) | At least `min_samples` points, R² ≥ `r2_min`, moving toward the threshold, and the ETA ≤ `horizon`. Goes critical when the ETA ≤ `critical`, and always once the threshold is reached. Optional gates for noisy sampled signals: `max_spacing` (the data must be this fine, so path loss needs the 1-min probe), `min_rise` (the fit must climb this much across the window), and `beyond_median` ("reached" needs the median of the last N samples, so one 100 % sample is not a prediction). |
| `baseline_deviation` | EWMA mean and variance, with a warm-up period | `k` of the last `n` samples are more than `k_sigma`·σ **and** `min_delta` away. Only samples within 2σ update the baseline, so a slow creep cannot teach it that the creep is normal. |
| `flap_counter` | State changes per window | Changes ≥ `max_changes`. A single maintenance blip (down, then up) is 2 changes and doesn't fire. |
| `countdown` | Days left, aged to now | ≤ `warn_days`; critical ≤ `critical_days` |
| `quota_headroom` | limit − used | Free ≤ `warn_free`. For public IPs, `warn_free: 0`, so a full session (2 gateway IPs + firewall = 3 of 3) warns that nothing else fits. |
| `level` | A fixed threshold, k of n | e.g. Pending pods > 0 for 3 samples in a row |

`signals.defs` in `design.yaml` sets the parameters, the counter → rate transform and the
mapping to model components. A collector component that maps to several model components (a
path, a cluster) has its impact computed for each one, and the alert shows the worst and lists
the others.

### Polling costs

| Source | Cost | At the default intervals |
|---|---|---|
| SSM Run Command, `az vm run-command` | Free | 2 SSM invocations every 5 min, plus 1 Azure invocation every 2 min (one combined script; Run Command takes 20–40 s and has one lock per VM). The probe adds 2 x 200 small ICMP packets per destination per 2 min. |
| CloudWatch `GetMetricData` | About $0.01 per 1,000 metrics requested | 12 metrics every 5 min ≈ 3,500/day ≈ **$0.035/day**. Keep requests small: one call, 30-min range, 300 s period. |
| EC2, ASG, Route 53 Domains, Budgets, `az network`/`az vm` reads | Free (API rate limits only) | — |
| Kubernetes API | Free | 3 `get` calls per cluster per minute |

The Budgets API is free to read, but AWS refreshes spend data only about 3 times a day, and
Azure consumption data lags by up to a day. The budget trend works in days, not minutes.

### Replay, lead time and false alarms

`replay` streams a CSV through the detectors one sample at a time, the way `watch` would see
it.
- **CSV columns:** `ts,signal,component,value,unit,event,note`. `ts` is ISO-8601 or epoch
  seconds. A row with `event=failure` marks when the failure became user-visible; its value can
  be empty.
- **Lead time** = failure time − first alert time, counting alerts on the failing component that
  fired at or before the failure.
- **False alarm:** an alert on a component that has no failure marked.
- **Late:** an alert that fired only after the failure.
- **ETA error:** for time-to-threshold alerts, replay also reports predicted crossing minus
  actual crossing, at the first alert, half-way through the lead time, and at the last sample
  before the failure. Severity escalation is reported too.

The synthetic series are in `tests/fixtures/series/`, made by `make_series.py` (seeded, so they
can be regenerated). Results:

| Series | Failure point | First alert | Lead time | ETA (predicted − actual) | False alarms |
|---|---|---|---|---|---|
| `pod-ip-drain` (2a pod subnet, ENI-sized drains, 1-min polls) | 0 free IPs | `subnet.free_ips` trend | 90 min (critical 39 min before) | +84 min at first alert, −3 min half-way, +5 min at the end | 0 (2b stays flat) |
| `conntrack-ramp` (az-fw leak, 5-min polls) | table 100 % full | `fw.conntrack_pct` trend | 115 min (critical 75 min before) | +50 min at first alert, then −15 / −17 min (the alert targets 90 %, so it lands before the 100 % failure) | 0 |
| `tunnel-loss` (0 → 8 % → 0, 20-packet pings, 5-min polls, RTT rises with queueing) | underlying loss reaches 5 % | `path.rtt_ms` baseline | 25 min | — | 0; the loss detector itself fires 10 min **after** the failure |
| `slowburn-loss-real` (**real** Session 1 samples, a copy of `docs/runs/slowburn-loss-replay.csv`: 20 pings every ~5 min, RTT flat) | loss crosses 5 % (18:56:31) | none: **not predicted** (the before-case) | — | — | **0** |
| `tunnel-loss-fine` (the same ramp, 0 → 8 % over 35 min, RTT flat, as the fine probe sees it: 1-min samples, 0.5 % resolution) | underlying loss crosses 5 % | `path.loss_pct` trend | **8 min** (472 s; critical 7 min before) | +4 min at first alert, −84 s half-way, −62 s at the end | 0 (10.10.0.74 stays flat) |
| `bgp-flap` (c1-t2 flaps 3 times, then stays down) | tunnel stays down | flap counter (AWS and Azure agree) | 11 min | — | 0 |
| `budget-burn` (~$3 per session, 8-hourly updates) | actual ≥ $15 | budget trend | 7.7 days (critical 2 days before) | −46 h at first alert, then −6 / −5 h | 0 |
| `healthy-noisy` (churn, a tunnel blip, loss blips, RTT spikes, a conntrack sine, scanner drops, slow spend) | none | — | — | — | **0** |

The first ETA is always late (positive) for drains that start after a flat period, because the
window still holds the flat part. It converges within a few minutes once the window is all
trend. The detector parameters were tuned on these synthetic series, so the Session numbers are
the real test.

### Measuring lead time in Sessions 1 and 2

1. **Start the watch:** start `python -m mindbridge watch` (MINDBRIDGE_DB set) after the layers
   are up and **before** the first injection. The quiet stretch between build and first injection
   is the false-alarm window. Each alert prints once, as `new alerts:`.
2. **Inject the slow burn and note the failure time.** The failure time is the first moment the
   test's own probe shows user-visible failure. The plan's slow-burn tests:
   - **Session 1: conntrack filling up.** Failure is the first `nf_conntrack: table full` in
     `journalctl -k` on the firewall, or the first failed curl in the test's probe. The expected
     lead is `fw.conntrack_pct`.
   - **Tunnel degradation.** Failure is the first sample of the test's own 5/s ping with
     sustained loss ≥ 5 %. With the fine probe, the expected lead is the `path.loss_pct` trend.
     `path.rtt_ms` leads only when the path degrades through congestion or rerouting; with
     pure loss (Session 1's netem ramp) RTT stays flat. If the degraded tunnel is not the one
     the ping hashes onto, expect no path alert. That is the ECMP limit, and the flap signals
     are what remain.
   - **Pod IP exhaustion.** Failure is the first `FailedCreatePodSandBox` with an
     IP-assignment message, or the first pod stuck in `ContainerCreating`. In secondary-IP mode
     the expected lead is `subnet.free_ips`; in prefix mode it is `subnet.free_aligned_28`
     (Session 2 showed free IPs are blind there). `k8s.ip_assign_errors` is the confirmation.
3. **Export the series and score it offline:**
   ```bash
   sqlite3 -header -csv "$MINDBRIDGE_DB" \
     "select ts, signal, component, value, unit, '' as event, '' as note from samples
      where ts between strftime('%s','2026-12-01 14:00') and strftime('%s','2026-12-01 18:00')" > /tmp/s1-conntrack.csv
   echo "<failure epoch>,fw.conntrack_pct,az-fw,,,failure,table full" >> /tmp/s1-conntrack.csv
   python -m mindbridge replay /tmp/s1-conntrack.csv
   ```
   Record the lead time, the false alarms over the whole session, and the ETA error next to the
   "predicted vs measured" columns in the results. The export contains no secrets, but keep it
   out of the repo with the rest of the session data.
4. **Before each injected failure in Tests 2–6:** also run `python -m mindbridge predict`, so
   that the alerts file is the recorded prediction.

### What gives real advance warning, and what can't

**Gives warning, with a measurable lead:**
- **Gradual resource exhaustion:**
  - `subnet.free_ips` during a scale-up (secondary-IP mode), `subnet.free_aligned_28` in
    prefix mode. On a /26 the aligned count is 0-2, so it is a "no /28 left" alarm before the
    next prefix allocation fails rather than a trend; a /19 pod subnet gives a real trend.
  - `fw.conntrack_pct` and `fw.nat_ports_pct` during a leak or slowly growing load. On the
    t4g.nano firewalls the table (1,048,576) is far from the binding limit; CPU and packet rate
    bind first.
  - Budget burn, over days.

  The trend has to be steady for about one window: 10 min at 1-min polls, 30–60 min at 5-min
  polls.
- **Calendar and quota limits** (`domain.expiry_days`, quotas): deterministic, so the warning
  can come as early as you like. A quota is a precondition (the next create fails), not a
  prediction of an outage.
- **Gradual path degradation:** the loss trend on the fine probe (about 8 min of lead on a
  0 → 8 % / 35 min ramp, in simulation a median of about 11 min). RTT helps only when the
  degradation is congestion or rerouting.
- **Firewall CPU and packet rate:** a steady load growth toward the CPU threshold or the
  packet-rate limit (estimate until Session 2).

**Gives some warning, sometimes:**
- **Flapping tunnels or BGP peers:** a warning only when the failure builds up (IKE or DPD
  trouble). The lead is a few flaps, i.e. minutes.
- **Node pressure conditions and a cordon before a drain:** minutes.
- **Spot rebalance recommendations:** not guaranteed to come before an interruption. The
  interruption notice itself is 2 minutes, and plain managed node groups don't put it into
  Kubernetes.

**Can't warn; these are the failure itself:**
- **Abrupt events:** a VM crash or stop, `vnet-gateway reset` (Test 3 instance-down), a peer ASN
  mismatch (Test 3 bgp-break), Spot reclaimed without a rebalance notice, an AZ or
  control-plane outage. The first state change is the failure. MindBridge's value there is the
  impact and the recovery time that come with the alert, not a lead time.
- **Bad configuration applied by Terraform** (Test 4 breaks A and B): only `precheck` can catch
  it, before the apply. In predict mode, `fw.nft_invalid_total` jumps only once asymmetric
  routing has started.
- **Pending pods, sandbox failures and IP-assignment errors:** symptoms that some pods are
  already failing. They are early only compared with a full outage of the service.
- **CloudWatch TunnelState:** 5-minute periods published 5–10 min late. It confirms an event
  after the fact.
- **Bursts faster than the poll interval:** a SYN flood that fills conntrack in under 5 min, or a
  single big deploy that takes all the free IPs at once.

**Known limits:**
- **No re-learning after a deliberate change:** a baseline does not re-learn after a deliberate
  permanent change, such as a new path with a higher RTT. Delete that series from the store to
  re-learn it.
- **Linear trends only:** the time-to-threshold fit is linear. An accelerating leak is predicted
  late, as the first ETAs above show. A decelerating one is predicted early.
- **Tuned on synthetic data:** the thresholds and gates were tuned on the synthetic series
  above. Session 1's real loss samples are a replay test now, and Session 2 is the next real
  measurement.

## Session 1 calibration

Session 1 (2026-11-23) ran Tests 3 and 4 and the two slow-burn tests against the live lab
(`docs/runs/test3-summary.md`, `test4-summary.md`, `slowburn-summary.md`). This table shows
what MindBridge predicted before each step, what was measured, and what changed in the model.

| Test | Step | MindBridge predicted | Measured | What changed |
|---|---|---|---|---|
| 3 | Path spread (8 iperf3 flows each way) | all 4 tunnels used (ECMP) | Azure→AWS 27/24/26/23 %, AWS→Azure 39/33/14/14 % (indicative) | Nothing: confirms the equal tunnel share the `vpn-tunnels` hop uses |
| 3 | BGP down on one tunnel, IPsec up (wrong peer ASN), 3.5 min | 25 % of flows hit, ≤ 90 s, auto | **0 of 16 flows** lost a packet; DOWN/0 routes within 93 s, ECMP moved the flows | New **clean withdrawal** mode (`bgp_clean_withdrawal_s` = 0 s, no packet loss, redundancy only). Tunnels and VPN connections are reported in both modes |
| 3 | Reset Azure gateway instance0 (2 of 4 tunnels) | 50 % of flows hit, ≤ 90 s, auto | **6 of 16 flows (38 %)**, 22–31 s gap; 4 tunnels back after **14 min 20 s** | New **silent failure** mode: `bgp_silent_s` 90 → 30 s (range 22–31). New **reduced-redundancy window** (`azure_gw_instance_rebuild_s` = 860 s), shown as "users recover in ~30 s; redundancy is reduced for ~14 min" and added to the severity (az-vpngw-i0: 23.75 → 27.87) |
| 3 | Path MTU | — (not modelled) | 1422 bytes both ways | Nothing: not a failure input |
| 3 | TCP MSS Azure → AWS | — (not modelled) | 1460 sent, 1350 arrived (the Azure gateway's clamp) | Nothing |
| 3 | TCP MSS AWS → Azure | — (not modelled) | 1220 offered, 1170 arrived | Nothing; follow-up in Session 2 |
| 4 | Baseline (appliance mode on) | all flows ok | 400/400 ok | Nothing |
| 4 | Break A: app spoke propagation removed | **block**: azure-to-aws broken, manual | 0/100 once settled; 14–20 % got through in the first seconds | Verdict confirmed. Added the **route-change convergence** note (`tgw_route_convergence_s` ≈ 5 s) for TGW propagation, route and association changes |
| 4 | Restore A | pass | 87–95 % in the first seconds, then 100/100 | Restores (creates) now get the convergence note too (`break-a-restore.json`) |
| 4 | Break B: appliance mode off | **block**: azure-to-aws degraded 50 % | **400/400 ok**, all 400 flows symmetric | Appliance-mode loss scoped to **VPC↔VPC** flows between AZ-pinned attachments (`loss_impact_by_path`: `vpn-vpc` = 0, measured). Every current flow is `vpn-vpc`, so turning it off now scores 0. The 50 % stays as an estimate for a future second spoke |
| 4 | Restore B: appliance mode back on | pass (nothing predicted) | **22–40 % ok for several minutes**; fw-invalid 50→404 (fw-a), 39→364 (fw-b); 100 % within ~14 min | New **transition risk** (`appliance_mode_transition_s` = 840 s). Precheck blocks any change to `appliance_mode_support`, in either direction, with a maintenance-window message and the measured numbers (`appliance-mode-enable.json`) |
| Slow burn | Path degradation, netem loss 0 → 8 % over 35 min | a loss or RTT warning before loss reached 5 % | **Not predicted, 0 false alarms**: 20 pings every 5 min read `0, 5, 0, 5, 10, 5, 15`; RTT flat | Fine loss probe: 200 pings at 0.2 s (0.5 % resolution), one sample per minute per destination, in one combined Run Command every 2 min. New loss trend detector with fine-data gates. The real samples replay as **not predicted, 0 false alarms** (`slowburn-loss-real.csv`, the before-case); the same ramp at fine resolution is predicted **8 min** before the 5 % crossing (`tunnel-loss-fine.csv`) |
| Slow burn | Connection-table fill, 20 → 600 new UDP flows/s over 35 min | table fills (it assumed 7,168) | limit **1,048,576**; peak ~8,600 entries (< 1 %); correctly no alert | `capacity` in `design.yaml`: `conntrack_max` 1,048,576 and peak 8,600 for fw-a/fw-b; 7,168 recorded as an Azure-firewall **count**. The collector labels count and max separately and rejects a swapped pair. New `fw.cpu_pct` and `fw.pps` signals with time-to-threshold detectors, because CPU and packet rate bind first on these VMs |

**Loss-ramp lead time, before and after:**

| Probe | Data | Result |
|---|---|---|
| Before: 20 pings every ~5 min | real Session 1 samples (`slowburn-loss-real.csv`) | not predicted, 0 false alarms |
| After: 200 pings, one sample a minute | synthetic, the same 0 → 8 % / 35 min ramp (`tunnel-loss-fine.csv`) | predicted 8 min (472 s) before the 5 % crossing, 0 false alarms. Over 300 seeded runs of the ramp, the median lead was about 11 min (10th percentile 8 min; 3 runs alerted only after the crossing), and at a steady 1 % background loss the detector raised 1 alert in 300 six-hour runs |

## Session 2 calibration

Session 2 (2026-11-23) ran Tests 5 and 6 on EKS and AKS (`docs/runs/test5-summary.md`,
`test6-summary.md`). This table shows what MindBridge saw or predicted, what was measured, and
what changed in the model. None of the new signals could be replayed against Session 2's own
data: the session recorded free-IP counts, not ENI address lists.

| Test | Step | MindBridge predicted or saw | Measured | What changed |
|---|---|---|---|---|
| 5 | Pod capacity, secondary IPs | — | 18 pods on 2 nodes, `Too many pods` (17 per node); node subnets 39 / 40 free IPs | Nothing: the per-node limit, not the subnet, binds |
| 5 | Pod-IP exhaustion, prefix delegation in the /26 node subnets | **No warning.** `subnet.free_ips` stayed at 33-57 while pods failed, so the free-IP trend had nothing to forecast. It saw the failure only after the fact through `k8s.sandbox_failures` and `k8s.ip_assign_errors` (up to 44 events): symptoms, not warnings | Rollout failed: new pods in `ContainerCreating` for 18 min, `failed to assign an IP address` with 34-49 free IPs, EKS gave up with `PodEvictionFailure`. No aligned /28 was left; users unaffected (old pods kept serving) | New signal **`subnet.free_aligned_28`** (ENI IPs and prefixes from `describe-network-interfaces`, 5 reserved addresses counted). Time-to-threshold → 0, gated on the `cloudbridge.io/pod-ip-mode` node label (new `k8s.pod_ip_mode` signal): node subnets in `prefix`, pod subnets in `prefix-custom-net`. Unit test: a /26 with 40 free IPs and 0 free aligned /28s |
| 5 | The prefix-delegation apply (precheck) | **pass**, no comment: the add-on, launch template and node group updates had no rule ("treated as safe") | Every node rolled; the drain stalled | New **node-roll** report for any `aws_eks_node_group` / `aws_launch_template` update or replace, or a VPC CNI `configuration_values` change: "all nodes replaced one at a time; workloads move; a drain can stall". Prefix delegation without custom networking now **blocks** (`prefix-only.json`) |
| 5 | Fix: prefix delegation + custom networking (pod /19s) | — | Rollout succeeded in 12 min; 204 pods (11×), `Too many pods` at 110 per node; pod subnets 8,073 free | The same change with custom networking on is a **warning** only: check the ENIConfigs exist first and the pod subnets' aligned /28s (`prefix-custom.json`) |
| 5 | Adding the secondary CIDR to the EKS node SG rule | **pass** (precheck had no rule for security-group rules) | Apply failed: the rule held a list of CIDRs, Terraform replaced it, AWS rejected the new one with `InvalidPermission.Duplicate`. Fixed with one rule per CIDR and `terraform state mv` | New **hazard**: an `aws_security_group_rule` replace whose `cidr_blocks` gains an entry while keeping an existing one **blocks** with "use one rule per CIDR" (`sg-rule-multi-cidr.json`) |
| 5 | Path probe with `enable_test_hosts = false` | **False alarm: 100 % loss** on `az-fw->10.10.0.10` | The host didn't exist; the path was fine | Probe targets are configurable (`path_probe_targets`) and resolved first: EC2 test hosts by Name tag, EKS frontend pods per AZ, or a LoadBalancer Service. An absent target is skipped as "unavailable: target absent" and gives no loss samples (tested) |
| 5 | Cross-cloud pod reachability, private DNS and PrivateLink | — (not modelled) | AKS → EKS pod direct ok (SNAT to the AKS node IP); EKS → AKS pod IP 100 % loss by design; via the ILB ok with the EKS pod IP kept; MSS 1258 | Nothing: not a failure input |
| 6 | NetworkPolicy, egress control, inbound DNAT to AKS | — (not modelled) | 14/14 policy checks; port rules don't stop 443; the inbound DNAT needed SNAT on the firewall | Nothing in MindBridge: these are configuration tests, not failure modes in the topology model |

