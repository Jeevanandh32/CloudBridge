# CloudBridge runbook

What to do when an alarm fires or the app fails over. Each section: **what it means → impact →
check → fix → confirm**. Commands assume `cd terraform/<layer>` and, for Azure,
`export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)`.

| Alarm / event | Fires when | User impact | Section |
|---|---|---|---|
| `cloudbridge-vpn-degraded` (CloudWatch) | 1 of 2 tunnels (or its BGP) down, 5 min | None — traffic on the other tunnel | [VPN degraded](#vpn-degraded) |
| `cloudbridge-vpn-down` (CloudWatch) | Both tunnels down, or no metrics | None for public traffic; **no private AWS↔Azure path** | [VPN down](#vpn-down) |
| `cloudbridge-bgp-peer-down` (Azure Monitor) | A BGP peer on the Azure gateway not connected | Same as above, seen from Azure | [BGP peer down](#bgp-peer-down) |
| Route 53 AWS health check unhealthy | AWS `/health` failing 3 × 10 s | ~1–2 min of errors, then served by Azure | [App failover](#app-failover-aws--azure) |

Why the VPN alarms don't touch user traffic: users reach each cloud's public load balancer over the
internet and Route 53 picks the healthy one. The VPN is only the private east-west path, so it is a
separate failure domain from failover.

---

## VPN degraded

**Means:** one tunnel is down or its BGP session isn't established. AWS reports a BGP VPN tunnel as
`DOWN` whenever BGP is down, even if IPsec is up.
**Impact:** none expected — BGP withdrew that path and traffic uses the other tunnel. Redundancy is gone.

**Check**
```bash
aws ec2 describe-vpn-connections \
  --query "VpnConnections[].VgwTelemetry[].[OutsideIpAddress,Status,StatusMessage,AcceptedRouteCount]" --output table
az network vpn-connection list -g cloudbridge-rg --query "[].{name:name,status:connectionStatus}" -o table
az network vnet-gateway list-bgp-peer-status -g cloudbridge-rg -n cloudbridge-vpngw -o table
```

| What you see | Layer | Likely cause |
|---|---|---|
| AWS `DOWN`, Azure connection `NotConnected` | IPsec / IKE | AWS endpoint maintenance (common, self-heals), PSK or IKE proposal mismatch |
| Azure connection `Connected`, BGP peer not `Connected` | BGP | Wrong ASN / peer IP / APIPA address (drift), BGP stuck |
| AWS status message mentions maintenance | AWS-side | Planned tunnel replacement — wait it out |

**Fix (least disruptive first)**
1. If AWS shows maintenance: wait ~10 min; it usually recovers on its own.
2. Check for drift (someone edited an ASN, IP, or PSK by hand) and put the code's values back:
   ```bash
   cd terraform/connectivity/vpn && terraform plan     # any change listed = drift
   terraform apply                                       # (user runs apply)
   ```
3. Reset the Azure side of the affected connection (re-runs IKE for that tunnel only):
   ```bash
   az network vpn-connection reset -g cloudbridge-rg -n cloudbridge-conn-aws-t1   # or -t2
   ```
4. Replace the AWS tunnel endpoint (new endpoint, same config):
   ```bash
   aws ec2 replace-vpn-tunnel --vpn-connection-id <vpn-id> --vpn-tunnel-outside-ip-address <tunnel-ip>
   ```

**Confirm:** both tunnels `UP` with ≥ 1 BGP route; both Azure peers `Connected`; alarm returns to OK
(an OK email is sent).

---

## VPN down

**Means:** both tunnels (or both BGP sessions) are down, or the VPN stopped reporting metrics.
**Impact:** no private path between clouds. BGP withdraws `10.20.0.0/16` from the AWS private route
table and `10.10.0.0/16` from Azure. AWS traffic to Azure's private IPs then matches the default
route (`0.0.0.0/0 → NAT`) and is dropped — private IPs aren't routable on the internet (fails closed).
**Public traffic (`app.jeevs.click`) is unaffected.**

**Check** — everything in [VPN degraded](#vpn-degraded), plus:
```bash
# Did the Azure gateway's public IP change (e.g. after a rebuild)? AWS's customer gateway must match it.
az network public-ip show -g cloudbridge-rg -n cloudbridge-vpngw-pip --query ipAddress -o tsv
aws ec2 describe-customer-gateways --query "CustomerGateways[].IpAddress" --output text

# Is the Azure gateway itself healthy?
az network vnet-gateway show -g cloudbridge-rg -n cloudbridge-vpngw --query provisioningState -o tsv

# Route tables: is the other cloud's prefix still there?
aws ec2 describe-route-tables --route-table-ids <private-rtb-id> --query "RouteTables[].Routes[]" --output table
az network vnet-gateway list-learned-routes -g cloudbridge-rg -n cloudbridge-vpngw -o table
```

**Fix**
1. Everything in [VPN degraded](#vpn-degraded), for both tunnels.
2. Customer-gateway IP doesn't match the Azure gateway IP → `terraform apply` in `connectivity/vpn`
   (it reads the IP from the network layer's state and replaces the customer gateway).
3. Reset the Azure gateway (both tunnels drop for a few minutes):
   ```bash
   az network vnet-gateway reset -g cloudbridge-rg -n cloudbridge-vpngw
   ```
4. Rebuild the VPN layer (~10 min; new tunnel IPs and PSKs are generated automatically):
   ```bash
   cd terraform/connectivity/vpn && terraform destroy && terraform apply   # (user runs these)
   ```

**Fallbacks if it stays down**
- BGP is the problem but IPsec is up → temporary static routes (`static_routes_only = true` on the AWS
  VPN connection, `bgp_enabled = false` + `address_space` on the Azure local gateways).
- Need cross-cloud calls now → use the other cloud's public endpoint over TLS until the VPN is back.

**Confirm:** as in VPN degraded, plus a pod-to-pod ping across clouds:
```bash
kubectl --context cloudbridge-eks run xtest --image=busybox:1.36 --restart=Never --rm -i -- ping -c 3 <aks-pod-ip>
```

---

## BGP peer down

**Means:** Azure Monitor sees a BGP peer (`169.254.21.1` or `169.254.22.1`) not connected for 5 min.
It's the Azure view of the same fault as the AWS alarms; one peer = [VPN degraded](#vpn-degraded),
both = [VPN down](#vpn-down).

**Check first:** is IPsec up but BGP down (connection `Connected`, peer not)? Then it's a BGP config
problem — compare against the IP plan:

| Setting | Must be |
|---|---|
| AWS ASN (on the Azure local gateways) | `64512` |
| Azure ASN | `65515` |
| Tunnel 1 BGP | AWS `169.254.21.1` ↔ Azure `169.254.21.2` |
| Tunnel 2 BGP | AWS `169.254.22.1` ↔ Azure `169.254.22.2` |

`terraform plan` in `connectivity/vpn` shows any drift from these values; `apply` fixes it.

---

## App failover (AWS → Azure)

**Means:** the Route 53 health check on the AWS ALB's `/health` failed 3 times in a row (10 s apart).
Route 53 now answers `app.jeevs.click` with the Azure IP.
**Impact (measured):** errors for ~1–2 min — Route 53 detects in ≤ ~60 s, then client resolvers keep
the AWS answer for up to its 60 s TTL. After that, Azure serves everything. Nothing has to be started
in Azure (warm standby).

**Check — what broke in AWS?**
```bash
aws route53 get-health-check-status --health-check-id <aws-health-check-id> \
  --query 'HealthCheckObservations[].StatusReport.Status' --output text      # what the checkers see
curl -s -w ' [%{http_code}]\n' http://<alb-dns-name>/health                   # deep check, direct
kubectl --context cloudbridge-eks -n cloudbridge get pods -o wide             # pods Ready?
kubectl --context cloudbridge-eks -n cloudbridge describe pod -l app=frontend | grep -A3 Readiness
kubectl --context cloudbridge-eks -n cloudbridge exec deploy/frontend -- \
  python3 -c "import socket;print(socket.gethostbyname('backend.cloudbridge.internal'))"
```

| What you see | Cause | Fix |
|---|---|---|
| Frontends `0/1`, backend name doesn't resolve | Backend DNS record missing (Test 1) | `tests/backend-dns.sh set` |
| No pods / deployments at 0 | App gone (Test 2) | `kubectl scale deploy/frontend deploy/backend --replicas=3` |
| Pods Pending, nodes NotReady | Node failure (Test 3) | Managed node group replaces the node; check `kubectl get nodes` |
| ALB 5xx but pods Ready | ALB / target group | Check target health in the target group |

**Failback:** automatic. Once `/health` passes 3 checks, Route 53 answers with AWS again; clients follow
within ~1–1.5 min (measured 68–93 s). Zero failed requests during failback in every test run.

**Confirm**
```bash
dig +short app.jeevs.click                 # the ALB's IPs again
curl -s http://app.jeevs.click/            # "cloud":"aws"
```

**Don't:** edit Route 53 records by hand to force failover — that's a control-plane call (us-east-1)
and fights the health checks. To force a failover for testing, break the AWS health instead.

---

## Teardown and rebuild

**Destroy (end of session), reverse order:** `global/dns` → `aws/eks` + `azure/aks` →
`connectivity/vpn` → `aws/network` + `azure/network`. Keep `bootstrap`. Uninstall Helm releases and
delete the app namespace first, so controller-created load balancers aren't orphaned:
```bash
kubectl --context cloudbridge-eks delete namespace cloudbridge      # removes ALB + NLB
helm --kube-context cloudbridge-eks uninstall aws-load-balancer-controller -n kube-system
kubectl --context cloudbridge-aks delete namespace cloudbridge      # removes the Azure LB rule
```
**Rebuild:** forward order; start `azure/network` first (gateway 30–45 min). Re-confirm the SNS
email subscription after rebuilding `connectivity/vpn`.
