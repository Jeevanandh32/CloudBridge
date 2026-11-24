# Test 5: pod networking across clouds (Session 2, 2026-11-23)

EKS: 2 × t3.medium Spot, VPC CNI. Node subnets are small on purpose (/26 per AZ).
AKS: 1 × B2als_v2, Azure CNI Overlay + Cilium (pods 10.244.0.0/16).

## Part 1: pod capacity, three IP modes

| Mode | Max pods per node | Test pods running (2 nodes) | What stopped it | Free IPs at the limit |
|---|---|---|---|---|
| Default (secondary IPs) | 17 | **18** | `FailedScheduling: Too many pods` (3 ENIs × 5 IPs + 2) | node subnets **39 / 40** |
| Prefix delegation, pods in the /26 node subnets | 110 | **rollout failed** | `failed to assign an IP address`: no free *aligned /28* left | node subnets **49 / 34** |
| Prefix delegation + custom networking (pod /19s in 10.10.64.0/18) | 110 | **204** | `Too many pods` (110 per node) | pod subnets **8,073 / 8,073** |

**What happened with prefix delegation in the /26s.**
- **The rollout stalled.** The new nodes came up with max-pods 110, but their pods sat in
  `ContainerCreating` for 18 min.
- **The cause was fragmentation.** Prefix delegation needs a free, aligned /28 (16 contiguous
  IPs). The old nodes' scattered secondary IPs and ENIs had broken up the /26s, so no whole /28
  was left even with 34–49 IPs free.
- **EKS gave up on the rollout.** The old nodes were cordoned but couldn't drain, because their
  replacement pods had no IPs. EKS failed the update with `PodEvictionFailure`.
- **Users weren't affected.** The app kept serving from the old pods.

**The fix was custom networking.**
- **Pod IPs move to their own subnets:** two /19s from a secondary VPC CIDR, which have plenty
  of aligned /28s.
- **The rollout then succeeded** in 12 min, and pod capacity went **11×** (18 → 204).
- **The other node IPs stay put:** nodes, the ALB and endpoints keep the original /26 subnets.

Getting there needed two infrastructure fixes:
1. **ENIConfigs before the nodes.** They must exist before the custom-networking nodes start,
   so they were built from the live subnet IDs.
2. **One security-group rule per CIDR.** The EKS node security-group rule was a single rule
   holding a list of CIDRs. Adding the secondary CIDR made Terraform replace it, and AWS rejected
   the replacement as a duplicate (`InvalidPermission.Duplicate`). The rule is now one per CIDR,
   migrated with `terraform state mv` so nothing was deleted.

## Part 2: cross-cloud pod reachability

| Direction | Result | Source IP seen by the far side |
|---|---|---|
| AKS pod → EKS pod IP (direct) | ✅ ping 12.8 ms, TCP, HTTP | AKS **node** IP 10.20.0.4 (Cilium SNATs overlay pods) |
| EKS pod → AKS pod IP (10.244.x) | ❌ 100 % loss, as designed | none: the overlay range isn't in any TGW table or BGP advertisement |
| EKS pod → AKS via the ILB 10.20.4.10 | ✅ frontend → backend | EKS **pod** IP 10.10.110.23, unchanged (`AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS=10.20.0.0/16`) |

The EKS pod's SYN arrived with MSS 1258, clamped on the way.

## Part 3: private DNS and private access

| Check | Result |
|---|---|
| AKS pod resolves `fw-a.cloudbridge.internal` (AWS private zone) | ✅ 10.10.240.40 |
| EKS pod resolves `fw.az.cloudbridge.internal` (Azure private zone) | ✅ 10.20.241.4 |
| EKS pod reads Azure Blob through the Private Endpoint | ✅ CNAME → privatelink, A 10.20.5.4, http 200 |
| AKS pod reads S3 through the interface endpoint, over the VPN | ✅ http 200 from 10.10.0.56 (after fixing the URL; see below) |
| The same S3 object through the public endpoint | ✅ 403: the bucket policy requires the endpoint |

**S3 PrivateLink URL.** Interface endpoints need the literal `bucket.` label:
`https://<bucket>.bucket.vpce-….s3.us-east-2.vpce.amazonaws.com/key`. Without it the TLS
certificate doesn't match (curl exit 60). The script and the Terraform output description are
fixed.

## MindBridge AI on this test

- **No early warning.** Free-IP counts stayed at 33–57 while pods couldn't get addresses, so
  the free-IP trend detector had nothing to forecast.
- **It detected the failure only after the fact,** through `k8s.sandbox_failures` and
  `k8s.ip_assign_errors` (up to 44 events). Those are symptoms, not warnings.
- **Model change needed:** forecast **free aligned /28 blocks** per subnet in prefix mode, not
  free IPs.
- **Precheck missed two risks:**
  - It passed the prefix-delegation change without flagging that it rolls every node.
  - It didn't know prefix mode would fail in fragmented /26s.
- **Rule change needed:** a node-group or CNI change is a node roll. In prefix mode, also check
  the subnets for free aligned /28s before applying.

Raw data: `test5-capacity-*.csv/.txt`, `test5-xcloud.txt`, `test5-private.txt`.
