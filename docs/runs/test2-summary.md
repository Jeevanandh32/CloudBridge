# Test 2: region loss, app and private link together (Session 3, 2026-11-23)

**Break, at 23:04:05 UTC:**
- **App loss:** EKS `frontend` and `backend` scaled to 0.
- **Private link loss:** a wrong shared key set on all **4** Azure VPN connections at once.
  The real PSKs were never read. The change took 52 s to apply.

**Probe:** from the laptop, 1 request/s, resolved fresh each time through 1.1.1.1. Each second
it also queried one Route 53 server and Traffic Manager directly, so each provider's switch is
timed on its own.

## Users

| Measure | Result |
|---|---|
| First failed request | break + 0.6 s |
| **Served by Azure** | **break + 41.7 s** (user-visible outage **41.0 s**) |
| Route 53 answers Azure | break + 40.6 s |
| Traffic Manager answers Azure | break + 35.4 s |
| **Back on AWS after restore** | **restore + 15.7 s** (1 failed request) |
| Route 53 / Traffic Manager answer AWS again | restore + 37.5 s / restore + 12.5 s |

v1 C2 (the same break with 2 tunnels and Route 53 only): clients reached Azure at about +102 s.

## Private network

| Event (sampled every ~15 s) | Time after break |
|---|---|
| All 4 Azure connections down, all 4 BGP peers down | 53 s |
| **Azure withdrew the AWS routes; the TGW withdrew the Azure routes** | 53 s |
| All 4 AWS tunnels DOWN | 98 s |
| Azure `cloudbridge-bgp-peer-down` alert fired | 53 s |
| CloudWatch `cloudbridge-vpn-c0/c1-degraded` → ALARM | 86 s / 96 s |
| CloudWatch `cloudbridge-vpn-link-down` → ALARM | 369 s (5-minute VPN metric period) |
| **Restore:** `terraform apply` in `connectivity/vpn` puts the 4 PSKs back (drift fix) | 4 resources updated in place |
| `vpn-link-down` → OK | 23:19:14, 11 s after the PSK-fix apply finished (23:19:03) |

## Findings

- **Users never depend on the VPN.** The public failover path (DNS → each cloud's own entry
  point) is a separate failure domain. Losing the app and the private link together still
  failed over in 41 s, more than twice as fast as v1.
- **BGP fails closed.** Both clouds withdrew each other's routes within a minute, so
  cross-cloud traffic stopped instead of leaking to the internet.
- **The alarms differ by design.** Azure's BGP alert is near real-time. CloudWatch VPN metrics
  have a 5-minute period, so `link-down` fired after 369 s.
- **Two script bugs fixed during the run:**
  - **JMESPath filter:** `&& !Config.PrivateZone` matches nothing, so it is now
    `Config.PrivateZone==false`. The same bug made the inventory script miss the public zone.
  - **Traffic Manager classifier:** the Azure answer is a CNAME to the firewall's FQDN, not
    its IP. Traffic Manager timings above come from the raw probe data with that corrected.

Raw data: `test2.txt`, `test2-break.txt`, `test2-probe.csv`, `test2-state.csv`, `test2-mindbridge.json`.
