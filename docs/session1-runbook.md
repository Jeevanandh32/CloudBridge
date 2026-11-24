# Session 1 runbook: Test 3 and Test 4 (no clusters)

Session 1 builds layers 1–5 and 9 from [`plan.md`](plan.md): the two hubs, the
app spoke with two test hosts, the Azure spoke, the 4-tunnel VPN and the budgets. There are no
EKS or AKS clusters. Traffic for both tests runs between the **Azure hub firewall**
(`10.20.241.4`) and the **AWS test hosts** `cloudbridge-app-host-a` (`10.10.0.10`, us-east-2a)
and `cloudbridge-app-host-b` (`10.10.0.74`, us-east-2b).

| | |
|---|---|
| Layers | `azure/hub`, `aws/hub`, `aws/spoke-app`, `azure/spoke-aks`, `connectivity/vpn`, `ops` |
| Tests | Test 3 (hybrid routing failover), Test 4 (hub-and-spoke routing through the firewall) |
| Time | About 5 h: 45 min build, 3 h of tests, 30 min teardown |
| Cost | About **$0.60/hr**, so about **$3** for the session ([breakdown](#session-cost)) |
| Scripts | `tests/test3-hybrid-routing.sh`, `tests/test4-hub-firewall.sh`, `tests/inventory.sh` |
| Results | `docs/runs/test3-*`, `docs/runs/test4-*` |

**Who runs what:** you run every `terraform apply` and `destroy`. The test scripts never run
terraform. When a test needs a change, the script prints the exact command, then waits for
you to press Enter. Every check in this runbook is read-only unless it says otherwise.

**How to reach the VMs:** no VM has SSH.
- **AWS (firewalls and test hosts):** SSM, with `aws ssm send-command` (the scripts use this)
  or `aws ssm start-session --target <instance-id>` (needs the Session Manager plugin).
- **Azure firewall:** `az vm run-command invoke`. It takes 20–40 s per call, runs one command
  at a time, and returns only the last 4 KB of output.

---

## 0. Prerequisites

```bash
aws sts get-caller-identity                     # IAM user with MFA, default region us-east-2
az login && az account show -o table            # Azure for Students subscription
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform version                               # >= 1.10
command -v jq python3                           # used by the scripts
tests/inventory.sh                              # should end with "CLEAN" before you start
```

You need these files. All are git-ignored.
- `terraform/backend.hcl`: the state bucket, already in place from v1.
- `terraform/connectivity/vpn/terraform.tfvars` and `terraform/ops/terraform.tfvars`, each
  setting `alert_email`.

Use the same pattern for every layer. `caffeinate -i` stops the Mac sleeping; if it sleeps,
the state upload fails.

```bash
cd terraform/<layer>
terraform init -backend-config=../../backend.hcl     # ops is one level up: -backend-config=../backend.hcl
terraform plan -out=layer.tfplan
caffeinate -i terraform apply layer.tfplan
```

---

## 1. Apply order

```
t=0      azure/hub ────────────────────────────────── (30–45 min, VPN gateway) ──┐
t=0      aws/hub (5 min) ── aws/spoke-app (3 min)                                │
                                                                                 ▼
t≈45     azure/spoke-aks (2 min) ── connectivity/vpn (10 min) ── ops (1 min)
```

### 1a. `azure/hub` (start first, terminal 1)

```bash
cd terraform/azure/hub && terraform init -backend-config=../../backend.hcl
terraform plan -out=layer.tfplan && caffeinate -i terraform apply layer.tfplan
```

While it builds, go on to 1b in a second terminal.

### 1b. `aws/hub`, then `aws/spoke-app` (terminal 2, in parallel)

```bash
cd terraform/aws/hub && terraform init -backend-config=../../backend.hcl
terraform plan -out=layer.tfplan && caffeinate -i terraform apply layer.tfplan
```

**Check aws/hub:**
```bash
# The 3 TGW route tables, by role
for r in spokes vpn inspection; do
  echo "== $r"
  RT=$(aws ec2 describe-transit-gateway-route-tables --filters Name=tag:Name,Values=cloudbridge-tgw-rt-$r \
        --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' --output text)
  aws ec2 search-transit-gateway-routes --transit-gateway-route-table-id $RT \
    --filters Name=state,Values=active,blackhole \
    --query 'Routes[].[DestinationCidrBlock,Type,State,TransitGatewayAttachments[0].ResourceType]' --output table
done
```

| Table | Expected now |
|---|---|
| `spokes` | `0.0.0.0/0` static → vpc (inspection) |
| `vpn` | `10.10.240.0/24` propagated → vpc |
| `inspection` | empty |

```bash
# Appliance mode is on (Test 4 break B turns it off)
aws ec2 describe-transit-gateway-vpc-attachments --filters Name=tag:Name,Values=cloudbridge-att-inspection \
  --query 'TransitGatewayVpcAttachments[0].Options.ApplianceModeSupport' --output text     # enable

# Firewall cloud-init finished, nftables and dnsmasq running (fw-a; repeat with cloudbridge-fw-b)
FWA=$(aws ec2 describe-instances --filters Name=tag:Name,Values=cloudbridge-fw-a Name=instance-state-name,Values=running \
       --query 'Reservations[].Instances[].InstanceId' --output text)
CID=$(aws ssm send-command --instance-ids $FWA --document-name AWS-RunShellScript \
       --parameters 'commands=["cloud-init status --wait; systemctl is-active nftables dnsmasq; nft list tables"]' \
       --query Command.CommandId --output text)
sleep 15; aws ssm get-command-invocation --instance-id $FWA --command-id $CID --query StandardOutputContent --output text
# status: done / active / active / table inet fw / table ip nat
```

If `send-command` says the instance isn't registered, wait 2–3 minutes for the SSM agent.

Then the app spoke:
```bash
cd ../spoke-app && terraform init -backend-config=../../backend.hcl
terraform plan -out=layer.tfplan && caffeinate -i terraform apply layer.tfplan
```

**Check aws/spoke-app.** Run the route-table loop again:

| Table | Expected now |
|---|---|
| `inspection` | `10.10.0.0/20` **propagated** → vpc (app). Test 4 break A removes this. |
| `vpn` | `10.10.0.0/20` **static** → vpc (inspection), plus `10.10.240.0/24` |

```bash
aws ec2 describe-instances --filters "Name=tag:Name,Values=cloudbridge-app-host-*" Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PrivateIpAddress,Placement.AvailabilityZone]' --output table
```

The test hosts reach SSM through the TGW and the firewall NAT, so they register a minute or
two after the firewalls do. If they never register, the egress path through the hub is broken.

### 1c. After azure/hub finishes: `azure/spoke-aks` → `connectivity/vpn` → `ops`

**Check azure/hub first:**
```bash
az network vnet-gateway show -g cloudbridge-rg -n cloudbridge-vpngw \
  --query '{state:provisioningState,activeActive:activeActive,sku:sku.name,asn:bgpSettings.asn}' -o table
az network public-ip list -g cloudbridge-rg --query '[].[name,ipAddress]' -o table   # instance0, instance1, fw
az vm run-command invoke -g cloudbridge-rg -n cloudbridge-fw --command-id RunShellScript \
  --scripts 'cloud-init status --wait; systemctl is-active nftables dnsmasq' --query 'value[0].message' -o tsv
```

```bash
cd terraform/azure/spoke-aks && terraform init -backend-config=../../backend.hcl
terraform plan -out=layer.tfplan && caffeinate -i terraform apply layer.tfplan

cd ../../connectivity/vpn && terraform init -backend-config=../../backend.hcl
terraform plan -out=layer.tfplan && caffeinate -i terraform apply layer.tfplan
```

After the VPN apply, confirm the SNS email subscription from the email AWS sends.

**Check the VPN (allow 5–10 min for all 4 BGP sessions):**
```bash
tests/test3-hybrid-routing.sh tunnels       # everything below in one go
```
or one at a time:
```bash
# AWS: 4 tunnels UP, each with accepted routes (only these fields: the full output has the PSKs)
aws ec2 describe-vpn-connections --filters Name=tag:Name,Values=cloudbridge-vpn-azure-c0,cloudbridge-vpn-azure-c1 \
  --query 'VpnConnections[].[Tags[?Key==`Name`]|[0].Value,VgwTelemetry[].[OutsideIpAddress,Status,AcceptedRouteCount]]' --output text

# Azure: 4 connections Connected, 4 BGP peers Connected
az network vpn-connection list -g cloudbridge-rg --query '[].[name,connectionStatus]' -o table
az network vnet-gateway list-bgp-peer-status -g cloudbridge-rg -n cloudbridge-vpngw -o table

# Azure learned from AWS: 10.10.0.0/20 and 10.10.240.0/24, each from all 4 peers
az network vnet-gateway list-learned-routes -g cloudbridge-rg -n cloudbridge-vpngw \
  --query "value[?origin=='EBgp'].[network,sourcePeer,asPath]" -o table
```

| Where | Expected |
|---|---|
| AWS tunnels | 4 × `UP`, `AcceptedRouteCount` ≥ 2 (`10.20.240.0/22`, `10.20.0.0/20`) |
| Azure BGP peers | `169.254.21.1`, `169.254.22.1`, `169.254.21.5`, `169.254.22.5`: all `Connected`, ASN 64512 |
| Azure learned routes | `10.10.0.0/20` and `10.10.240.0/24` × 4 peers, AS path `64512` |
| TGW `inspection` table | `10.20.240.0/22` and `10.20.0.0/20` propagated over **2 attachments** each (one per VPN connection; ECMP then spreads over each connection's 2 tunnels) |

The TGW route table check:
```bash
RT=$(aws ec2 describe-transit-gateway-route-tables --filters Name=tag:Name,Values=cloudbridge-tgw-rt-inspection \
      --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' --output text)
aws ec2 search-transit-gateway-routes --transit-gateway-route-table-id $RT --filters Name=state,Values=active \
  --query 'Routes[].[DestinationCidrBlock,Type,length(TransitGatewayAttachments)]' --output table
```

**End-to-end check: firewalls, ping, HTTP, DNS across clouds:**
```bash
tests/test3-hybrid-routing.sh check
```
It runs, read-only:
- `cloud-init status` on fw-a, fw-b and the Azure fw.
- From the Azure fw: `ping` and `curl http://<host>/` to `10.10.0.10` and `10.10.0.74`. Each
  host answers with its hostname.
- From the Azure fw: `dig @10.20.241.4 fw-a.cloudbridge.internal`. Expected answer: `10.10.240.40`.
- From AWS fw-a: `dig @10.10.240.40 fw.az.cloudbridge.internal`. Expected answer: `10.20.241.4`.

> **Known issue:** see [Known issues](#known-issues-found-while-writing-the-scripts). The
> AWS → Azure name lookup loops between the two forwarders until the Azure dnsmasq config
> is fixed.

Finally, the budgets:
```bash
cd ../../ops && terraform init -backend-config=../backend.hcl
terraform plan -out=layer.tfplan && terraform apply layer.tfplan
```

---

## 2. Test 3: hybrid routing failover

All four subcommands save their results to `docs/runs/test3-*`. Run them in this order.

### 2a. Path selection (ECMP over the 4 tunnels)
```bash
tests/test3-hybrid-routing.sh paths
```
- Installs iperf3 on both test hosts (via SSM, through the firewall NAT) and on the Azure fw.
  It starts `iperf3 -s` on the hosts.
- Reads the 4 Azure connection byte counters.
- From the Azure fw, runs 8 parallel iperf3 flows, 15 s, to each host in both directions.
  That is about 120 MB in total.
- Reads the counters again. `test3-paths.csv` gives MB and share per tunnel, each way.

**Expect:** more than one tunnel carries traffic in each direction. TGW ECMP picks the
tunnel for AWS → Azure, and the Azure gateway picks it for Azure → AWS, so the two
directions can differ. For AWS's own per-tunnel view, run
`tests/test3-hybrid-routing.sh tunnels` again about 10 minutes later. It reads the
CloudWatch `TunnelDataIn` / `TunnelDataOut` metrics, which are published every 5 minutes.

### 2b. BGP down on the busiest tunnel, IPsec still up (changes Azure, restores itself)
```bash
tests/test3-hybrid-routing.sh bgp-break           # ~10 min
```
1. Sends a short ICMP flood to `10.10.0.10` and picks the tunnel whose counters grew most.
   That is the tunnel the ping flow uses.
2. Starts a 5/s ping (`ping -D -O -i 0.2`) from the Azure fw to `10.10.0.10`.
3. Sets that tunnel's LNG (`cloudbridge-lng-aws-<cX-tY>`) to peer ASN 65000 instead of 64512.
   Azure then rejects the TGW's BGP OPEN, but IPsec stays up. The script waits 180 s.
4. Restores ASN 64512 and watches for 240 s. If the script dies, an EXIT trap restores the ASN.

**Output:** `test3-bgp-break.txt` gives each gap in the ping replies relative to the break
and the restore. `test3-bgp-break-state.csv` has BGP peers, Azure connections and AWS
tunnels about every 20 s.

**Expect:**
- About 30–90 s of loss: the BGP hold time, until both sides withdraw the path.
- Or no gap, if the reroute was faster than 2 pings.
- Azure keeps showing the connection `Connected` while AWS shows that tunnel `DOWN`.

### 2c. One Azure gateway instance down (changes Azure, recovers by itself)
```bash
tests/test3-hybrid-routing.sh instance-down       # instance0 by default; ~15 min
```
Runs `az network vnet-gateway reset --gateway-vip <cloudbridge-vpngw-instance0 IP>`, which
takes down tunnels c0-t1 and c0-t2. It uses the same 5/s ping and watches for 12 minutes.
The script first prints which tunnel carries the ping flow. If that tunnel is on c1, the
ping will show no gap; use `instance-down instance1` to hit the ping's path instead.

**Expect:**
- Half the tunnels and 2 of the 4 BGP peers go down, then recover in a few minutes.
- The ping loses at most a hold time's worth of replies; there is no outage.
- `test3-instance-down-instance0.txt` gives the gaps, when the first peer went down, and
  when all 4 were back.

### 2d. MTU and MSS
```bash
tests/test3-hybrid-routing.sh mtu
```
- **Path MTU each way:** a DF-ping binary search, Azure fw → host-a and host-a → Azure fw,
  plus `tracepath`.
- **SYN MSS, Azure → AWS:** the Azure fw curls host-a on port 80; tcpdump runs on host-a.
- **SYN MSS, AWS → Azure:** host-a sends TCP DNS to the Azure fw on port 53; tcpdump runs on
  the Azure fw.
- **Configured clamp:** the nftables `mss` chain values (1360).

**Expect:**
- Path MTU about 1400–1430 (IPsec overhead).
- MSS at the far side ≤ 1360. The AWS firewall clamps flows to and from `10.20.0.0/16`, and
  the Azure gateway may clamp lower.
- host-a sends an MSS of 8961, because its MTU is 9001.

---

## 3. Test 4: hub-and-spoke routing through the firewall

### 3a. Baseline
```bash
tests/test4-hub-firewall.sh baseline
```
From the Azure fw, this sends 200 curls to each host, 20 at a time. Each curl uses its own
fixed source port (`--local-port`), so the flows hash independently across tunnels, AZs and
firewalls. **Expect 200/200 for both hosts.** Results: `docs/runs/test4-baseline.txt`.

### 3b. Break A: TGW route table mistake (you run 2 applies)
```bash
tests/test4-hub-firewall.sh break-a
```
1. Prints the inspection table, then the command for you to run:
   ```bash
   cd terraform/aws/spoke-app && terraform plan -var propagate_to_inspection=false -out=break-a.tfplan && terraform apply break-a.tfplan
   ```
2. After you press Enter, waits until `10.10.0.0/20` has gone from the inspection table, then
   runs the 200 + 200 curls again. **Expect ~0%** (curl exit 28, timeout).
3. Shows the evidence (`test4-break-a-evidence.txt`):
   - `search-transit-gateway-routes` on the **inspection** table: there is no `10.10.0.0/20`,
     so the firewalls have no route back to the spoke.
   - The **vpn** table still sends `10.10.0.0/20` to the inspection VPC, and BGP still
     advertises it to Azure. So Azure keeps sending traffic, which is why it blackholes
     instead of failing over.
   - `nft list chain inet fw forward` counters before and after: the `ct state new` accept
     counter grew and `fw-invalid` / `fw-drop` did not. The firewalls forwarded the SYNs and
     the TGW dropped them.
4. Prints the restore command, waits, confirms the route is back, and reruns the curls
   (`test4-break-a-restored.txt`):
   ```bash
   cd terraform/aws/spoke-app && terraform plan -out=restore.tfplan && terraform apply restore.tfplan
   ```

**During break A the test hosts drop off SSM**: their internet egress returns through the same
missing route. That's expected; break A only uses the firewalls.

Optional, manual: Reachability Analyzer from fw-a's ENI to host-a's ENI shows the missing TGW
route. This creates resources and costs $0.10 per analysis; delete the path afterwards.

### 3c. Break B: appliance mode off (you run 2 applies)
```bash
tests/test4-hub-firewall.sh break-b           # ~20 min, mostly waiting for flow logs
```
1. Prints the command for you to run:
   ```bash
   cd terraform/aws/hub && terraform plan -var appliance_mode=disable -out=break-b.tfplan && terraform apply break-b.tfplan
   ```
2. Waits until the attachment shows `ApplianceModeSupport = disable`, then starts conntrack
   samplers on fw-a and fw-b (SSM, asynchronous) and reruns the curls. **Expect partial
   failure.**
   - Without appliance mode, the TGW keeps each flow in the AZ it entered. A request that
     goes through fw-b to host-a (2a) comes back through fw-a.
   - fw-a never saw that SYN, so its conntrack marks the SYN-ACK `invalid` and nftables drops
     it.
   - How the TGW spreads VPN traffic over AZs decides the exact split. With an even hash it
     is about 50% per host. If everything lands in one AZ, the host in that AZ gets ~100%
     and the other ~0%.
3. Shows the evidence (`test4-break-b-evidence.txt`):
   - The `fw-invalid` count on each firewall since the break (`journalctl -k`), with sample
     log lines and the nft counter.
   - Conntrack on each firewall: `SYN_SENT [UNREPLIED]` flows are SYNs that firewall
     forwarded whose replies went to the other firewall.
   - **Flow logs** from the inspection VPC. The bucket comes from
     `terraform -chdir=terraform/aws/hub output -raw flowlog_bucket`, and the script waits up
     to 15 min for delivery. For every source port it finds which firewall ENI saw the
     request and which saw the reply. `test4-break-b-flows.csv` lists each flow as
     `symmetric` or `ASYMMETRIC`, next to whether its curl failed.
   - **The stray replies show as ACCEPT, not REJECT.** The firewall security group allows
     `10.0.0.0/8`, so the VPC accepts the packet; nftables drops it inside the VM. The
     evidence is the reply on the wrong ENI.
4. Prints the restore command, waits, confirms `enable`, and reruns the curls
   (`test4-break-b-restored.txt`):
   ```bash
   cd terraform/aws/hub && terraform plan -out=restore.tfplan && terraform apply restore.tfplan
   ```

---

## 4. Destroy (end of session, reverse order)

```
ops ── connectivity/vpn ──┬── azure/spoke-aks ── azure/hub      (terminal 1)
                          └── aws/spoke-app ── aws/hub          (terminal 2, in parallel)
```

```bash
cd terraform/ops              && terraform destroy     # budgets only, free: keeping them is fine too
cd ../connectivity/vpn        && caffeinate -i terraform destroy
# terminal 1
cd terraform/azure/spoke-aks  && terraform destroy
cd ../hub                     && caffeinate -i terraform destroy      # gateway delete takes 10–20 min
# terminal 2
cd terraform/aws/spoke-app    && terraform destroy
cd ../hub                     && terraform destroy
```

Then the final inventory:
```bash
tests/inventory.sh
```
- It lists instances, volumes, TGWs and attachments, VPN connections, customer gateways,
  EIPs, NAT gateways, load balancers, EKS clusters, VPC endpoints, non-default VPCs and
  CloudWatch alarms, in us-east-2 and us-east-1.
- It also lists `cloudbridge*` S3 buckets, Route 53 health checks and private zones, and every
  Azure resource and public IP.
- The last line must read `CLEAN: ...`. `NOT CLEAN` lists what's left;
  `INVENTORY INCOMPLETE` means a login expired.
- The state bucket and Azure's NetworkWatcher are kept on purpose. Resources in the
  subscription that aren't CloudBridge's are listed separately for you to check.

---

## Session cost

These are approximate list prices, with no clusters.

| Item | ≈ $/hr |
|---|---|
| Transit Gateway attachments × 4 (inspection, app, 2 VPN) | 0.20 |
| AWS Site-to-Site VPN connections × 2 | 0.10 |
| Azure VPN gateway VpnGw1AZ, active-active | 0.19–0.36* |
| S3 interface endpoint, 1 AZ | 0.01 |
| 4 × t4g.nano (fw-a, fw-b, 2 test hosts) | 0.02 |
| Azure fw VM B2ats_v2 | 0.01 |
| Public IPv4: AWS × 2 (firewalls), Azure × 3 | 0.03 |
| Flow logs, VPN data transfer, iperf3 burst | < 0.05 |
| **Total** | **≈ $0.60/hr**, so ≈ $3 for a 5 h session |

\* Confirm the VpnGw1AZ rate in the pricing calculator. At the top of the range the total is
about $0.75/hr.

---

## Known issues found while writing the scripts

These block, or would mislead, part of a check or test. They are not fixed here.

1. **DNS AWS → Azure loops.**
   - **Where:** `terraform/azure/hub/fw-cloud-init.yaml.tftpl`.
   - **Cause:** the rule `server=/cloudbridge.internal/10.10.240.40` (and `.56`) also matches
     `az.cloudbridge.internal`, because dnsmasq matches subdomains. A query for
     `fw.az.cloudbridge.internal` from AWS fw-a goes to the Azure fw, which sends it back to
     the AWS firewalls, and so on until it times out.
   - **Effect:** the `dig @10.10.240.40 fw.az.cloudbridge.internal` check fails.
   - **Fix:** add a more specific line, `server=/az.cloudbridge.internal/168.63.129.16`.
2. **Test 4 break B will not show REJECTed flow-log records.** The plan expects them, but the
   firewall SG accepts all of `10.0.0.0/8`, so the stray return packets are logged as
   ACCEPT on the wrong firewall's ENI. The script uses that asymmetry as the evidence.
3. **Break A cuts SSM to the test hosts.** Their egress to the SSM endpoints returns through
   the same missing route. No step in break A needs the hosts.
- **Changing a firewall cloud-init template replaces both AWS firewalls in a single apply.** MindBridge
  AI's pre-change check found this (`user_data_replace_on_change = true` on `aws_instance.fw`). During
  a test session, roll them one at a time so the other firewall keeps carrying its AZ:
  `terraform apply -target='aws_instance.fw[0]'`, check it with `tests/test3-hybrid-routing.sh check`,
  then `terraform apply -target='aws_instance.fw[1]'`. A plain `terraform apply` is fine when nothing
  is running yet.
- **Run MindBridge AI's pre-change check before every apply during a session:**
  `terraform plan -out=tf.tfplan && terraform show -json tf.tfplan > /tmp/plan.json && (cd ../../../tools && python -m mindbridge precheck /tmp/plan.json)`.
  Adjust the `../` levels for the layer you're in. Exit code 2 means the change breaks or degrades an
  important flow; read the output before applying. Plan files can contain secrets (VPN PSKs): git ignores `*.tfplan`, but delete
  `tf.tfplan` and `/tmp/plan.json` afterwards.
