# Session 3 runbook: Test 1 and Test 2 (everything up, two DNS providers)

Session 3 builds all 9 layers from [`plan.md`](plan.md): everything from
[Session 2](session2-runbook.md) plus `global/dns`, which serves `app.jeevs.click` from two DNS
providers at once. Test 1 shows the name still resolves and still fails over with Route 53
completely unreachable. Test 2 removes the AWS app and the whole private link together and
times the failover, the BGP withdrawal, the alarms and the restore. The session ends with a
MindBridge AI live rerun of the slow-burn loss ramp, now with the fine loss probe.

| | |
|---|---|
| Layers | Session 2 layers + `global/dns` |
| Tests | Test 1 (DNS with no single point of failure), Test 2 (region loss), MindBridge AI slow-burn rerun |
| Time | About 5–6 h: 1 h build, 15–30 min delegation wait, 3 h of tests, 45 min teardown |
| Cost | About **$0.90–1.05/hr**, so about **$5** for the session ([breakdown](#session-cost)) |
| Scripts | `k8s/deploy.sh`, `tests/test1-dns-no-spof.sh`, `tests/test2-region-loss.sh`, `tests/inventory.sh` |
| Results | `docs/runs/test1-*`, `docs/runs/test2-*`, `docs/runs/slowburn3-*` |

**Who runs what:** you run every `terraform apply` and `destroy`. The test scripts never run
terraform. Test 2's restore prints the exact command and waits for you to press Enter. The
scripts **do change** these things, and each puts them back:
- the EKS replica counts (Tests 1 and 2);
- on fw-a, a transient `unbound` and a temporary nftables table `inet cbt1` that drops Route 53
  (Test 1). An EXIT trap lifts the block, and a systemd timer on fw-a deletes the table after
  45 min even if the laptop dies. Nothing is written to `/etc/nftables.conf`, so a reboot clears it too;
- the shared key of the 4 Azure VPN connections (Test 2). This one is **not** restored by the
  script: your `terraform apply` in `connectivity/vpn` puts the real PSKs back.

**Addresses and names used below:**

| What | Value |
|---|---|
| App name | `app.jeevs.click` |
| AWS firewalls | fw-a `10.10.240.40`, fw-b `10.10.240.56` (SSM). Each has its own public IP and IGW, so its internet access doesn't depend on Azure |
| Azure firewall | `10.20.241.4`, public IP `az network public-ip show -g cloudbridge-rg -n cloudbridge-fw --query ipAddress -o tsv` (DNAT port 80 → AKS ILB `10.20.4.10`) |
| EKS app | context `cloudbridge-eks`, namespace `cloudbridge`, deployments `frontend`, `backend` |
| AKS | context `cloudbridge-aks` |
| VPN | Azure connections `cloudbridge-conn-aws-{c0,c1}-{t1,t2}` in `cloudbridge-rg`; AWS VPN connections tagged `cloudbridge-vpn-azure-{c0,c1}` |
| Alarms | CloudWatch `cloudbridge-vpn-link-down` (all 4 tunnels), `cloudbridge-vpn-{c0,c1}-{degraded,down}`; Azure Monitor `cloudbridge-bgp-peer-down` |
| Route 53 | zone `jeevs.click`: failover records for `app` (PRIMARY = ALB alias, SECONDARY = Azure firewall public IP), with health checks |
| Azure DNS | zone `jeevs.click` in `cloudbridge-rg`: `app` CNAME → Traffic Manager priority profile (ALB first, Azure firewall IP second, `/health` every 10 s, 3 failures) |
| Registrar | 4 name servers: 2 Route 53 + 2 Azure DNS |

---

## 0. Prerequisites

Everything from [Session 2 §0](session2-runbook.md#0-prerequisites), plus:

```bash
command -v dig jq python3            # dig is used against the TLD and every name server
dig +short NS click.                 # the .click TLD servers answer
aws route53domains get-domain-detail --region us-east-1 --domain-name jeevs.click \
  --query '{ns:Nameservers[].Name,autoRenew:AutoRenew}'   # 4 awsdns servers now; autoRenew must stay false
tests/inventory.sh                   # should end with "CLEAN" before you start
```

### The EKS IP-mode flags must be off when the cluster is created

Session 2 turned prefix delegation and custom networking on and back off. **Session 3 must
build with all of them off from the start.** Custom networking needs its ENIConfigs before any
node starts. A cluster created with `enable_custom_networking = true` launches nodes that find
no ENIConfig, so their pods never get an IP. The secondary CIDR only exists for those pod subnets.

Put these in the git-ignored tfvars files, not on the command line with `-var`, so no later
apply can bring them back:

| File | Setting |
|---|---|
| `terraform/aws/eks/terraform.tfvars` | `enable_prefix_delegation = false`, `enable_custom_networking = false` (plus `admin_cidrs`) |
| `terraform/aws/spoke-app/terraform.tfvars` | `enable_secondary_cidr = false`, `enable_test_hosts = true` |

```bash
grep -H '^ *enable_' terraform/aws/eks/terraform.tfvars terraform/aws/spoke-app/terraform.tfvars
```

`enable_test_hosts = true` is the opposite of Session 2. The test hosts
(`cloudbridge-app-host-a` 10.10.0.10, `-b` 10.10.0.74) are MindBridge AI's path-probe targets
for the slow-burn rerun (`path_probe_targets` in `tools/mindbridge/design.yaml`). Without them
the probe falls back to the EKS frontend pods, which Tests 1 and 2 scale to 0.

### Start MindBridge AI before the first apply finishes

The quiet stretch between the build and the first test is MindBridge's false-alarm window.
Use two terminals, both with the same database:

```bash
export MINDBRIDGE_DB=~/.mindbridge/session3.db
cd tools
python -m mindbridge watch --only aws_subnets,aws_vpn,aws_vpn_cloudwatch,azure_vpngw,aws_firewalls,kubernetes,aws_spot,azure_quotas,domain,budgets
```
```bash
export MINDBRIDGE_DB=~/.mindbridge/session3.db
cd tools
python -m mindbridge watch --only azure_firewall    # its own process: one ~100 s Run Command every 2 min
```

Start them once `connectivity/vpn` is up. Collectors for layers that don't exist yet only
report "unavailable". **The Azure firewall collector holds the VM's Run Command lock for about
100 s of every 120 s.** Any `az vm run-command invoke` you or a script send in that time waits
for it. Test 1 and Test 2 don't use the Azure firewall's Run Command. The slow-burn ramp in §6
uses it twice, once to start and once to stop.

---

## 1. Apply order

```
t=0      azure/hub ───────────────────────────── (30–45 min, VPN gateway) ──┐
t=0      aws/hub ── aws/spoke-app ── aws/eks (15 min)                       │
                                                                            ▼
t≈45     azure/spoke-aks ── connectivity/vpn ──┬── ops
                                               └── azure/aks (10 min)
t≈60     LB controller ── k8s/deploy.sh ── (ALB ready, 2–3 min) ── global/dns ── wait for delegation
```

1. **Session 1 layers**, as in [Session 1 §1](session1-runbook.md#1-apply-order): `azure/hub`
   first, `aws/hub` and `aws/spoke-app` in parallel, then `azure/spoke-aks`, `connectivity/vpn`
   and `ops`. Confirm the SNS email subscription. Check:
   ```bash
   tests/test3-hybrid-routing.sh tunnels     # 4 tunnels UP, 4 BGP peers Connected
   tests/test3-hybrid-routing.sh check       # firewalls, ping + HTTP to the test hosts, DNS both ways
   ```
2. **`aws/eks`**, as soon as `aws/spoke-app` is done, exactly as in
   [Session 2 §1](session2-runbook.md#1-apply-order) (`caffeinate -i terraform apply`).
3. **`azure/aks`**, after `azure/spoke-aks`.
4. **Kubeconfig and the Load Balancer Controller**, the commands from
   [Session 2 §1](session2-runbook.md#kubeconfig-and-the-load-balancer-controller). Check:
   the EKS nodes are `MAX_PODS` 17 with mode `secondary-ip`, and the aws-node env shows
   `ENABLE_PREFIX_DELEGATION=false` and `AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=false`.
5. **The app:**
   ```bash
   k8s/deploy.sh
   ALB=$(kubectl --context cloudbridge-eks -n cloudbridge get ingress frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   FWPIP=$(az network public-ip show -g cloudbridge-rg -n cloudbridge-fw --query ipAddress -o tsv)
   curl -s http://$ALB/health      # {"status":"ok","cloud":"aws"}   (a new ALB needs 2–3 min)
   curl -s http://$FWPIP/health    # {"status":"ok","cloud":"azure"}
   ```
   Both must answer before `global/dns`. The layer looks up the ALB, and both providers'
   health checks start on the first apply.

---

## 2. `global/dns`

```bash
cd terraform/global/dns && terraform init -backend-config=../../backend.hcl
terraform plan -out=layer.tfplan && caffeinate -i terraform apply layer.tfplan
```

This creates the Route 53 health checks and failover records, the Azure DNS zone, the Traffic
Manager profile and the `app` CNAME. It also **changes the registrar** to 2 Route 53 + 2 Azure
name servers.

**Save the restore command now.** It puts the 4 Route 53 servers back at the registrar at the
end of the session. Once the layer is destroyed its outputs are gone, so you can't read the
command then:

```bash
terraform output -raw restore_nameservers_command > ~/cloudbridge-restore-ns.sh   # outside the repo
cat ~/cloudbridge-restore-ns.sh
terraform output route53_nameservers; terraform output azure_nameservers; terraform output traffic_manager_fqdn
```

**Check right away** (no waiting needed, these ask the providers directly):
```bash
tests/test1-dns-no-spof.sh check      # saved to docs/runs/test1-check.txt
```

| Section | Expected now |
|---|---|
| registrar | 2 × `awsdns`, 2 × `azure-dns` |
| delegation from the TLD | still the **old** 4 `awsdns` servers on some or all TLD servers (TTL 900 s) |
| `app` at every Route 53 server | `A` = the ALB's IPs, no CNAME |
| `app` at every Azure server | `CNAME <profile>.trafficmanager.net` |
| Traffic Manager | profile Online; ALB endpoint priority 1 and Azure firewall endpoint priority 2, both `Online`; TTL, path `/health`, interval 10, tolerated failures 3 |
| Health checks | Route 53 `r53hc_aws=N/N r53hc_azure=N/N`; HTTP `/health` 200 on the ALB and the firewall IP |

## 3. Wait for the delegation

The TLD keeps the old NS set for its TTL (900 s), and the registrar needs a few minutes to
send the change to the registry. Wait until every `.click` server delegates to the new 4:

```bash
until tests/test1-dns-no-spof.sh delegation; do sleep 120; done     # DELEGATION OK
tests/test1-dns-no-spof.sh check                                    # rerun; now the full picture
```

**Expect** in the rerun:
- every TLD server lists the registrar's 4 servers;
- each provider's apex NS set is the 4 delegated servers (see [requirements](#requirements-on-the-dns-layer));
- the public resolvers return the ALB (via Route 53) or a CNAME chain through
  `trafficmanager.net` to the ALB (via Azure DNS). Which one varies by resolver and by query.

Public resolvers that cached the old child NS set (Route 53's apex NS, TTL 2 days) keep asking
only Route 53 until it expires. That makes no difference to these tests: Route 53 still serves
the zone, and Test 1 uses its own resolver with an empty cache.

---

## 4. Test 1: DNS failover with no single point of failure

Results go to `docs/runs/test1-*`. Each part saves MindBridge AI's what-if prediction for the
component it breaks (`*-mindbridge.json`, taken from `docs/mindbridge/whatif-report.json`;
`MB_REFRESH=1` reruns `whatif` first), so you can compare the result with the prediction.

### 4a. Route 53 unreachable: does resolution survive, and what does it cost?
```bash
tests/test1-dns-no-spof.sh provider-loss         # ~10 min
```
1. Resolves every Route 53 name server of the zone to IPv4 (and IPv6, if there are any). It
   uses both the hosted zone's 4 servers and the `awsdns` names in the TLD delegation.
   Saved to `test1-provider-loss-ips.txt`.
2. Installs `unbound` on fw-a with SSM (apt goes out through fw-a's own IGW). It runs as a
   transient unit `cb-unbound` on `127.0.0.1:5335`, with the iterator only (no DNSSEC
   validation) and a 1 s TTL cap. The package's own `unbound` service is disabled, so the
   firewall's dnsmasq and resolv.conf are untouched.
3. **Step `normal`:** 20 queries for `app.jeevs.click`. Before each one the message, rrset,
   negative and infra caches are flushed, so every query starts from the root.
4. Adds `table inet cbt1` on fw-a: an `output` hook chain that **drops** (no reject, so it
   looks like an outage: timeouts) every Route 53 IP.
5. **Step `blocked-cold`:** 20 queries, all caches flushed each time. This is a resolver that
   meets the outage for the first time on every query.
6. **Step `blocked-warm`:** 20 queries that keep the infra cache (server RTT and timeouts).
   This is a resolver that has already learned Route 53 is dead.
7. Prints the nft drop counters and lifts the block.

For each query it records the wall time, the status, which provider answered and how many
Route 53 servers unbound tried. A CNAME to `trafficmanager.net` can only come from Azure DNS; a
plain `A` comes from Route 53. Unbound's infra cache is flushed before each query, so what is
left in it afterwards shows which servers it tried.

**Expect:**

| Step | Success | Answered by | Time |
|---|---|---|---|
| normal | 20/20 | a mix of `route53` and `azure-dns` | the baseline: root → `.click` → zone, typically 100–400 ms |
| blocked-cold | **20/20** | **only `azure-dns`** | baseline **+ one timeout per Route 53 server tried**: unbound starts unknown servers at a 376 ms timeout, so +0.4 to +1.2 s |
| blocked-warm | 20/20 | only `azure-dns` | close to normal: unbound skips the servers it has marked as timing out |

The MindBridge AI prediction for `dns-route53` is "degraded, auto-recovery ~3 s", and only
the cold step can reach that. Record both numbers.

### 4b. Failover with Route 53 completely unreachable
```bash
tests/test1-dns-no-spof.sh failover-without-route53     # ~11 min with the defaults
BLOCK_ELB=1 tests/test1-dns-no-spof.sh failover-without-route53   # optional: a total Route 53 outage
```
1. Blocks Route 53 on fw-a again, for the whole run. A 3-query precheck must show only
   `azure-dns` answers.
2. fw-a polls every 2 s. Each poll flushes unbound, resolves `app.jeevs.click`, and curls
   `/health` on the address it got. Meanwhile the laptop samples Traffic Manager endpoint
   status and Route 53 health checker results every ~10 s (`test1-failover-no-r53-healthchecks.csv`).
3. After `BASELINE` (40 s) it **scales EKS `frontend` to 0**. The ALB has no targets, so
   `/health` returns 503.
4. After `OUTAGE` (240 s) it scales `frontend` back. **Route 53 stays blocked**, so the failback
   is also decided by Traffic Manager alone. After `RECOVERY` (300 s) it lifts the block.

**Expect:**
- Every answer comes from Azure DNS. Before the break the chain is
  `app → CNAME <profile>.trafficmanager.net → CNAME <alb>.elb.amazonaws.com → A`, and the curl
  says `"cloud":"aws"`.
- **Failover:** Traffic Manager marks the ALB Degraded after 3 failed probes at 10 s, so about
  30–40 s. The next poll then gets `A <Azure firewall IP>` and `"cloud":"azure"`. fw-a flushes
  its cache on every poll, so the Traffic Manager TTL doesn't count here; for a real user it
  comes on top.
- **Failback:** Traffic Manager needs a passing probe on the ALB (a few seconds once the pods
  are Ready), then AWS answers again.
- **What this proves:** failover works with every Route 53 server of the zone unreachable. The
  decision came from Traffic Manager's health checks; Route 53's own checks (also recorded)
  never reached this resolver.
- **The `BLOCK_ELB=1` variant:** the ALB's name (`*.elb.amazonaws.com`) is also served by
  Route 53. In a total Route 53 outage the AWS answer can't resolve even while AWS is healthy.
  Before the break, expect `SERVFAIL` or `none`. After Traffic Manager fails over, expect the
  Azure IP, which needs no Route 53. Record this honestly: the AWS side of the app depends on
  Route 53 through the ALB's own name.

Files: `test1-failover-no-r53.txt`, `.csv` (every poll), `-healthchecks.csv`, `.meta`,
`-mindbridge.json`.

```bash
tests/test1-dns-no-spof.sh cleanup      # lifts any block and stops unbound on fw-a
```

---

## 5. Test 2: region loss (app + all 4 tunnels)

Before the break, record MindBridge AI's live prediction too (README, "Measuring lead time"):
```bash
(cd tools && python -m mindbridge predict)          # alerts-<ts>.md/.json in docs/mindbridge
```

### 5a. Break
```bash
caffeinate -i tests/test2-region-loss.sh break      # ~13 min
```
1. Waits for 10 `"cloud":"aws"` answers in a row, each resolved fresh through `1.1.1.1`
   (`RESOLVER=` to change it).
2. Starts the probe in the background. It keeps running until `restore`, so don't close the
   terminal. Each second it does three things:
   - resolves `app.jeevs.click` through the public resolver (no OS cache) and sends one HTTP
     request to that address;
   - asks one Route 53 server directly;
   - asks Traffic Manager's name server directly.
   That times each provider's own switch, as well as what a user sees.
3. Saves MindBridge AI's prediction for the VPN connections, the 4 tunnels, the ALB, the EKS
   nodes and both failover mechanisms (`test2-mindbridge.json`). The what-if sweep is N-1, one
   component at a time. Compare each row with its part of the result, not with the combined
   outage.
4. **Break:** scales `frontend` and `backend` to 0. At the same moment it runs
   `az network vpn-connection shared-key update --value cbWrongKeyForTest2 -o none` on all 4
   connections, in parallel. The real PSKs are never read or printed.
5. Samples the state every ~15 s for 12 min (`test2-state.csv`). The slow Azure calls run in
   parallel, and each value carries its sample's start time. It records:
   - the AWS tunnels (status and accepted routes);
   - the Azure connections and BGP peers;
   - the Azure learned eBGP routes;
   - the Azure prefixes in the TGW `inspection` table;
   - all `cloudbridge-vpn-*` CloudWatch alarms;
   - the latest `cloudbridge-bgp-peer-down` alert instance.

**Expect** (v1 C2: users on Azure at +102 s; tunnels down within 1–3 min; alarms at about
2 and 7.5 min):
- users reach Azure in about 1–2 min, the same as an app-only loss. The DNS path never
  touches the VPN;
- all 4 tunnels DOWN and all 4 BGP peers down within a few minutes. Azure's learned eBGP
  routes drop to 0, and the TGW `inspection` table loses `10.20.0.0/20` and `10.20.240.0/22`;
- `cloudbridge-vpn-*-degraded`, then `-down` and **`cloudbridge-vpn-link-down`** go to ALARM.
  The 5-minute metric period is the floor;
- `cloudbridge-bgp-peer-down` **Fired** (1-min frequency, 5-min window).

### 5b. Restore
```bash
caffeinate -i tests/test2-region-loss.sh restore    # ~12 min
```
1. Starts sampling every 10 s, then prints this command and waits:
   ```bash
   cd terraform/connectivity/vpn && terraform plan -out=restore.tfplan && terraform apply restore.tfplan
   ```
   The plan must show `shared_key` changes on the 4 `azurerm_virtual_network_gateway_connection`
   resources (values hidden as sensitive) and nothing else. That is the drift fix: the apply
   puts the PSKs back. Delete `restore.tfplan` afterwards, because plan files hold the PSKs.
2. When you press Enter, it scales the app back to the saved replica counts and watches for
   10 min.
3. Writes `test2.txt`:
   - the state timeline (relative to the break, then to "fixed" = when you pressed Enter);
   - the v1 analyser on the probe: failed requests, failover time and failback time;
   - each provider's own switch times;
   - the exact CloudWatch alarm history, the Azure alert instance, and the Activity Log times
     of the 4 shared-key writes (the break and the fix).

**Expect:** tunnels and BGP back about 30 s after the apply (v1), alarms back to OK on
their next evaluation, and users back on AWS about 1 min after the scale-up, with 0 failed
requests during failback.

---

## 6. MindBridge AI live slow-burn rerun (loss ramp with the fine probe)

This is the Session 1 path-degradation test again ([`slowburn-summary.md`](runs/slowburn-summary.md)):
netem loss on the Azure firewall toward `10.10.0.0/16`, from 0 to 8 % in 25 steps over 35 min.
In Session 1 the 20-pings-every-5-minutes probe missed it. The `azure_firewall` collector now
sends 200 pings at 0.2 s to each probe target, one sample per minute (0.5 % resolution). The
offline replay of the same ramp predicted the 5 % crossing 8 min ahead. This is the live test.

**Before you start:** Test 2 is restored (4 tunnels UP), the app is scaled back, and both
`watch` processes from §0 have run for at least 15 min. Note the start time.

**Start the ramp.** It is a transient unit on the firewall, so the Run Command returns at once
and doesn't hold the lock the collector needs:
```bash
az vm run-command invoke -g cloudbridge-rg -n cloudbridge-fw --command-id RunShellScript --query 'value[0].message' -o tsv --scripts '
cat > /var/tmp/cb-netem-ramp.sh <<"EOF"
IF=$(ip route get 10.10.0.10 | awk "{for (i = 1; i < NF; i++) if (\$i == \"dev\") print \$(i+1)}")
tc qdisc del dev $IF root 2>/dev/null
tc qdisc add dev $IF root handle 1: prio bands 3 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
tc qdisc add dev $IF parent 1:3 handle 30: netem loss 0%
tc filter add dev $IF parent 1: protocol ip prio 1 u32 match ip dst 10.10.0.0/16 flowid 1:3
: > /var/tmp/cb-netem-ramp.log
for i in $(seq 0 24); do
  p=$(awk -v i=$i "BEGIN { printf \"%.2f\", 8 * i / 24 }")
  tc qdisc change dev $IF parent 1:3 handle 30: netem loss ${p}%
  echo "$(date +%s) $p" >> /var/tmp/cb-netem-ramp.log
  sleep 84
done
EOF
systemctl reset-failed cb-netem-ramp 2>/dev/null; systemd-run --unit cb-netem-ramp bash /var/tmp/cb-netem-ramp.sh
sleep 3; tc -s qdisc show | grep -A2 netem'
```

What to watch:
- **The 5 % crossing** is step 15 (5.00 %), 21 min into the ramp. It is the failure time,
  taken from the ramp log.
- **MindBridge:** the `azure_firewall` terminal prints `new alerts:`. Expect a `path.loss_pct`
  trend alert on `az-fw->app-host-a` and `az-fw->app-host-b` **before** the crossing, and no
  alert from other signals.
- **ECMP:** loss is applied on the firewall itself, so every tunnel is affected and both
  targets should trend together.

**Stop the ramp** after the last step (35 min), or sooner if the alerts have come:
```bash
az vm run-command invoke -g cloudbridge-rg -n cloudbridge-fw --command-id RunShellScript --query 'value[0].message' -o tsv --scripts '
systemctl stop cb-netem-ramp 2>/dev/null
IF=$(ip route get 10.10.0.10 | awk "{for (i = 1; i < NF; i++) if (\$i == \"dev\") print \$(i+1)}")
tc qdisc del dev $IF root 2>/dev/null; tc qdisc show dev $IF
awk "\$2 >= 5 { print \"5% crossing:\", \$1; exit }" /var/tmp/cb-netem-ramp.log; cat /var/tmp/cb-netem-ramp.log | tr "\n" " "'
```
Save the ramp log text to `docs/runs/slowburn3-ramp.txt`.

**Score it offline** (README, "Measuring lead time"). Export the session's samples, add the
failure row, and replay:
```bash
sqlite3 -header -csv "$MINDBRIDGE_DB" \
  "select ts, signal, component, value, unit, '' as event, '' as note from samples
   where ts >= <session start epoch>" > /tmp/s3-loss.csv
echo "<5% crossing epoch>,path.loss_pct,az-fw,,,failure,netem loss 5%" >> /tmp/s3-loss.csv
(cd tools && python -m mindbridge replay /tmp/s3-loss.csv)
(cd tools && python -m mindbridge predict --since 2h)     # the alerts file is the recorded prediction
```
Record the lead time (crossing minus first alert), the ETA error, and the false alarms over
the whole session. The alerts during Test 2 (tunnels down) and Test 1 (frontend at 0) are
real failures, not false alarms. Write the result into `docs/runs/slowburn3-summary.md` next
to Session 1's "not predicted". Keep `/tmp/s3-loss.csv` out of the repo.

---

## 7. Destroy (end of session)

**`global/dns` goes first, while the ALB still exists.** The layer looks up the ALB, so its
destroy plan fails once the ingress is gone.

```bash
tests/test1-dns-no-spof.sh cleanup                       # fw-a: no block, no unbound (fw-a is destroyed anyway)
cd terraform/global/dns && terraform destroy             # health checks, records, Azure zone, Traffic Manager
```

**Then put the 4 Route 53 servers back at the registrar** with the command you saved in §2.
Run it straight after the destroy: until it runs, half the delegation points at Azure servers
that no longer have the zone.
```bash
cat ~/cloudbridge-restore-ns.sh && bash ~/cloudbridge-restore-ns.sh
aws route53domains get-domain-detail --region us-east-1 --domain-name jeevs.click \
  --query '{ns:Nameservers[].Name,autoRenew:AutoRenew}'  # 4 awsdns, autoRenew false
```
If the file is lost, rebuild the command by hand. These are the 4 servers of the hosted zone,
which the destroy keeps:
```bash
ZID=$(aws route53 list-hosted-zones-by-name --dns-name jeevs.click --query "HostedZones[?Name=='jeevs.click.'].Id | [0]" --output text | sed 's#/hostedzone/##')
aws route53 get-hosted-zone --id $ZID --query DelegationSet.NameServers --output text
# aws route53domains update-domain-nameservers --region us-east-1 --domain-name jeevs.click \
#   --nameservers Name=<ns1> Name=<ns2> Name=<ns3> Name=<ns4>
```

Then the rest, as in [Session 2 §6](session2-runbook.md#6-destroy-end-of-session): the
Kubernetes load balancers and the LB controller, then `azure/aks` and `aws/eks`, then the
Session 1 order.
```bash
kubectl --context cloudbridge-eks -n cloudbridge delete ingress frontend
kubectl --context cloudbridge-aks -n cloudbridge delete svc frontend
aws elbv2 describe-load-balancers --region us-east-2 --query 'LoadBalancers[].LoadBalancerName'   # wait for []
helm --kube-context cloudbridge-eks uninstall aws-load-balancer-controller -n kube-system
cd terraform/azure/aks && terraform destroy          # terminal 1
cd terraform/aws/eks   && terraform destroy          # terminal 2
# then ops ── connectivity/vpn ──┬── azure/spoke-aks ── azure/hub
#                                └── aws/spoke-app ── aws/hub
```
Stop both `watch` processes before or during the destroy: their collectors only fail
read-only calls, but the database is cleaner without an hour of "unavailable".

**Finally, the inventory and the delegation:**
```bash
tests/inventory.sh                             # last line: CLEAN: ...
tests/test1-dns-no-spof.sh delegation          # DELEGATION OK once every TLD server lists the 4 awsdns again (up to 15 min)
```
The inventory lists Route 53 health checks and every Azure resource, so a leftover Traffic
Manager profile, Azure DNS zone or health check shows there. The public hosted zone
`jeevs.click` is listed as "not CloudBridge" and is kept on purpose. It was created when the
domain was registered.

---

## Session cost

These are approximate list prices, with everything up.

| Item | ≈ $/hr |
|---|---|
| Session 2 (network, both clusters, ALB, test hosts) | 0.85–1.00 |
| Route 53 health checks × 2 (fast interval, one non-AWS endpoint) | < 0.01 |
| Azure DNS zone, Traffic Manager profile + 2 external endpoints with fast probing | < 0.01 |
| DNS queries (probes at 1/s, unbound tests) | < 0.01 |
| **Total** | **≈ $0.90–1.05/hr**, so ≈ $5 for a 5–6 h session |

DNS resources are billed per month, prorated. The plan estimates about $1.50/month if they were
left up.

---

## Requirements on the DNS layer

The Test 1 and 2 scripts rely on these. `tests/test1-dns-no-spof.sh check` shows each one.

1. **Records and their shapes.** Route 53 answers `app` with an `A` record (an alias to the ALB
   for PRIMARY, the Azure firewall IP for SECONDARY), never a CNAME. Azure DNS answers `app`
   with a CNAME to `*.trafficmanager.net`. The scripts tell the providers apart by this shape.
2. **Traffic Manager endpoints.** Priority 1 is an external endpoint whose target is the ALB's
   **DNS name**, so it answers with a CNAME to `*.elb.amazonaws.com`. Priority 2 is an external
   endpoint whose target is the Azure firewall's **IPv4 address**, so it answers with an `A`.
   Monitor: HTTP, port 80, path `/health`, interval 10 s, 3 tolerated failures, expected
   status 200. The profile TTL should be short (10–30 s), or the laptop probe in Test 2 sees
   the TTL on top of the health checks.
3. **One profile in `cloudbridge-rg`.** The scripts take the first Traffic Manager profile in
   the resource group. The Azure DNS zone is `jeevs.click` in `cloudbridge-rg`.
4. **Route 53 health checks findable.** The AWS check uses `FullyQualifiedDomainName` = the
   ALB name (contains `elb.amazonaws.com`) and the Azure check uses `IPAddress` = the firewall
   IP. The scripts look them up by those fields.
5. **Apex NS records match the delegation.** In both zones, the apex NS set should list the
   same 4 servers as the registrar. Route 53's apex NS should include the 2 Azure servers, and
   Azure DNS's apex NS should include the 2 Route 53 servers. Otherwise a resolver that adopts
   the child NS set (Route 53's apex NS TTL is 2 days) ends up with a single provider, and
   loses the redundancy this test is about. `check` prints each provider's apex NS next to the
   TLD delegation.
6. **`restore_nameservers_command` is a complete, ready-to-run command** for all 4 of the
   hosted zone's Route 53 servers (`aws route53domains update-domain-nameservers --region
   us-east-1 ...`). Destroying the layer must not delete the hosted zone, because the
   restore points back to it.
7. **The Azure firewall DNAT stays on port 80** (`/health` → AKS ILB) and the ALB has no host
   rule. Both scripts send requests to the bare IP with `Host: app.jeevs.click`.

## Notes and known limits

- **The unbound resolver is a measuring tool, not a fix.** It runs on fw-a only because fw-a
  has its own internet path and SSM. Nothing in the app uses it, and `cleanup` (or a reboot)
  removes it.
- **"Route 53 unreachable" means the zone's Route 53 servers.** Default Test 1 blocks only the
  zone's servers. The ALB's own name is also served by Route 53 (other servers), so
  `BLOCK_ELB=1` is the full-outage variant. It shows that the AWS answer itself depends on
  Route 53, while the Azure answer doesn't.
- **Laptop probe timing.** Each sample is one fresh lookup through a public resolver, so a
  resolver's cache of the 60 s alias TTL (Route 53) or the Traffic Manager TTL still applies,
  as it does for a user. The direct queries to one Route 53 server and to Traffic Manager
  show when each provider itself switched.
- **State samples are about 15 s apart, and the Azure calls take 10–30 s each.** Times from
  `test2-state.csv` are accurate to about ±20 s. The CloudWatch alarm history and the Activity
  Log in `test2.txt` give the exact times.
- **Plan files and PSKs.** `restore.tfplan` in `connectivity/vpn` contains the real PSKs. Git
  ignores `*.tfplan`; delete it after the apply.
