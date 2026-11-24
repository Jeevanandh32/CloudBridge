# CloudBridge runbook

What to do when an alarm fires. Each section covers what it means, the impact, the check, the
fix, and how to confirm. Commands assume `cd terraform/<layer>` and, for Azure,
`export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)`.
The v1 runbook is archived in [archive/v1/runbook.md](archive/v1/runbook.md).

| Alarm | Fires when | User impact | Section |
|---|---|---|---|
| `cloudbridge-vpn-c0-degraded` / `-c1-degraded` (CloudWatch) | 1 tunnel (or its BGP) down on that connection | None: ECMP carries traffic on the other 3 | [VPN degraded](#vpn-degraded) |
| `cloudbridge-vpn-c0-down` / `-c1-down` (CloudWatch) | Both tunnels on one connection down, which means one Azure gateway instance is unreachable | None: the other instance's 2 tunnels carry traffic | [VPN down](#vpn-down) |
| `cloudbridge-vpn-link-down` (CloudWatch) | All 4 tunnels down, or no metrics | **No private AWS↔Azure path.** Public traffic is unaffected. | [VPN down](#vpn-down) |
| `cloudbridge-bgp-peer-down` (Azure Monitor) | A BGP peer on the Azure gateway not connected for 5 min | Same as above, seen from Azure | [BGP peer down](#bgp-peer-down) |
| Route 53 AWS health check unhealthy / Traffic Manager `aws-alb` Degraded | AWS `/health` failing 3 × 10 s | ~36–42 s of errors, then served by Azure | [App failover](#app-failover-aws--azure) |
| A DNS provider unreachable | Resolvers can't reach Route 53 or Azure DNS | About +140 ms per lookup; answers continue | [DNS provider unreachable](#dns-provider-unreachable) |

The VPN is the private east-west path only. Users reach each cloud through its public entry point
(the AWS ALB, or the Azure firewall's public IP), so a VPN fault is a separate failure domain from
app failover.

---

## VPN degraded

**Means:** one tunnel is down or its BGP session isn't established. AWS reports a BGP tunnel as
`DOWN` whenever BGP is down, even if IPsec is up.
**Impact:** none expected. BGP withdraws that path, and the Transit Gateway and the Azure
gateway spread traffic over the remaining tunnels (ECMP). One layer of redundancy is gone.

**Check**
```bash
aws ec2 describe-vpn-connections --filters Name=tag:Project,Values=cloudbridge \
  --query "VpnConnections[].{id:VpnConnectionId,t:VgwTelemetry[].[OutsideIpAddress,Status,AcceptedRouteCount]}" --output json
az network vpn-connection list -g cloudbridge-rg --query "[].{name:name,status:connectionStatus}" -o table
az network vnet-gateway list-bgp-peer-status -g cloudbridge-rg -n cloudbridge-vpngw -o table
```

| What you see | Layer | Likely cause |
|---|---|---|
| AWS `DOWN`, Azure connection `NotConnected` | IPsec / IKE | AWS endpoint maintenance (common, self-heals), PSK or IKE proposal mismatch |
| Azure connection `Connected`, BGP peer not `Connected` | BGP | Wrong ASN, peer IP or APIPA address (drift) |
| AWS status message mentions maintenance | AWS side | Planned tunnel replacement: wait it out |

**Fix (least disruptive first)**
1. AWS shows maintenance: wait about 10 min.
2. Drift: `cd terraform/connectivity/vpn && terraform plan`. Any change listed is drift, and
   `terraform apply` (you run it) puts the code's values back.
3. Reset the Azure side of one connection:
   `az network vpn-connection reset -g cloudbridge-rg -n cloudbridge-conn-aws-c0-t1` (or the affected one).
4. Replace the AWS tunnel endpoint:
   `aws ec2 replace-vpn-tunnel --vpn-connection-id <id> --vpn-tunnel-outside-ip-address <ip>`.

**Confirm:** all 4 tunnels `UP` with at least 1 BGP route each, all 4 Azure peers `Connected`,
and the alarm back to OK.

---

## VPN down

**Means:**
- **One connection down (`-c0-down` / `-c1-down`):** both tunnels to one Azure gateway
  instance are down. Usually that instance is being patched, was reset, or failed.
- **Link down:** all 4 tunnels are down.

**Impact:**
- **One connection:** none, because the other instance carries traffic.
- **Link down:** BGP withdraws the Azure prefixes from the Transit Gateway's inspection route
  table, and the AWS prefixes from Azure. Cross-cloud traffic then fails closed: the firewalls
  have no route for it, and private IPs aren't routable on the internet. **Public traffic is
  unaffected.**

**Check:** everything in [VPN degraded](#vpn-degraded), plus:
```bash
# Do the customer gateways still match the Azure gateway instance IPs (e.g. after a rebuild)?
az network public-ip list -g cloudbridge-rg --query "[?starts_with(name,'cloudbridge-vpngw')].{n:name,ip:ipAddress}" -o table
aws ec2 describe-customer-gateways --filters Name=tag:Project,Values=cloudbridge --query "CustomerGateways[].IpAddress" --output text
# Is the gateway healthy?
az network vnet-gateway show -g cloudbridge-rg -n cloudbridge-vpngw --query provisioningState -o tsv
# What does each side still know?
aws ec2 search-transit-gateway-routes --transit-gateway-route-table-id <inspection-rt> --filters Name=type,Values=propagated --output table
az network vnet-gateway list-learned-routes -g cloudbridge-rg -n cloudbridge-vpngw -o table
```

**Fix**
1. Everything in [VPN degraded](#vpn-degraded), for each affected tunnel.
2. A customer gateway IP doesn't match → `terraform apply` in `connectivity/vpn`. It reads the IPs
   from azure/hub's state and replaces the customer gateway.
3. Reset one gateway instance only:
   `az network vnet-gateway reset -g cloudbridge-rg -n cloudbridge-vpngw --gateway-vip <instance-ip>`.
4. Rebuild the VPN layer (about 10 min; new tunnel IPs and PSKs are generated):
   `terraform destroy && terraform apply` in `connectivity/vpn` (you run these).

**Confirm:** as in VPN degraded, plus `tests/test3-hybrid-routing.sh check` passes (ping and
HTTP from the Azure firewall to both AWS test hosts).

---

## BGP peer down

**Means:** Azure Monitor sees one of the 4 AWS BGP peers not connected for 5 min. It's the Azure
view of the same faults as the AWS alarms.

**Check first:** is IPsec up but BGP down (connection `Connected`, peer not)? Then it's a BGP
config problem. Compare against the IP plan:

| Setting | Must be |
|---|---|
| AWS ASN (Transit Gateway, on the Azure local network gateways) | `64512` |
| Azure ASN | `65515` |
| c0 tunnels (Azure instance0) | AWS `169.254.21.1` ↔ Azure `.21.2`, AWS `169.254.22.1` ↔ Azure `.22.2` |
| c1 tunnels (Azure instance1) | AWS `169.254.21.5` ↔ Azure `.21.6`, AWS `169.254.22.5` ↔ Azure `.22.6` |

`terraform plan` in `connectivity/vpn` shows any drift from these values; `apply` fixes it.

---

## App failover (AWS → Azure)

**Means:** both DNS providers have moved `app.jeevs.click` to Azure:
- **Route 53:** the AWS health check (deep `/health` on the ALB, 10 s × 3) is unhealthy, so the
  SECONDARY record (the Azure firewall IP) answers.
- **Traffic Manager:** the `aws-alb` endpoint is Degraded, so it answers with the Azure firewall's
  FQDN.

**Impact:** about 36–42 s of errors (measured in Tests 1 and 2), then users are served by Azure.
The VPN isn't involved.

**Check**
```bash
tests/test1-dns-no-spof.sh check        # answers from every Route 53 and Azure name server, health checks, HTTP
az network traffic-manager endpoint list -g cloudbridge-rg --profile-name cloudbridge-app \
  --query "[].[name,priority,endpointMonitorStatus]" -o table
curl -s http://<alb-dns>/health         # what is failing on AWS?
kubectl --context cloudbridge-eks -n cloudbridge get pods
```

**Fix:** restore the AWS app (pods, nodes, ALB targets). Failback is automatic once `/health`
passes again: 14.5–15.7 s measured.

**If Azure fails too:** both providers answer AWS (PRIMARY / priority 1) when every endpoint is
unhealthy, so there is no automatic third path.

## DNS provider unreachable

**Means:** resolvers can't reach one provider's name servers. The registrar lists 2 Route 53 + 2
Azure DNS servers, so resolvers retry the other provider.

**Impact:** measured with Route 53 fully unreachable: lookups took about +140 ms, and 304/304 were
answered by Azure DNS.

**Check**
```bash
tests/test1-dns-no-spof.sh delegation   # the TLD lists all 4 servers
dig @ns1-01.azure-dns.com app.jeevs.click +norecurse   # (current Azure server names: terraform -chdir=terraform/global/dns output azure_nameservers)
```

**Note:** the ALB's own name is served by Route 53. In a total Route 53 outage, AWS can't be
resolved even if it's healthy, so users end up on Azure.

## After destroying `global/dns`

Destroying the layer does **not** reset the registrar name servers or the zone's apex NS. Run
`~/cloudbridge-restore-ns.sh` (saved by the session 3 runbook right after the apply). It puts the 4
Route 53 servers back in both places. Then confirm:
```bash
aws route53domains get-domain-detail --region us-east-1 --domain-name jeevs.click --query '{auto:AutoRenew,ns:Nameservers[].Name}'
# auto-renew must stay false
```
