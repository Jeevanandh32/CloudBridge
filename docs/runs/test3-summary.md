# Test 3: hybrid routing failover (Session 1, 2026-11-23)

Setup: 4 IPsec tunnels with eBGP (TGW ASN 64512 ↔ Azure active-active VpnGw1AZ ASN 65515),
ECMP on both sides. Probes: 16 parallel 5/s pings from the Azure hub firewall to an AWS test host
(10.10.0.10), so ECMP hashes the flows across the tunnels independently.

| Check | MindBridge predicted | Measured |
|---|---|---|
| Path spread (8 iperf3 flows each way) | all 4 tunnels used | Azure→AWS 27/24/26/23 %, AWS→Azure 39/33/14/14 % (Azure counters lag by minutes, so these shares are indicative) |
| BGP down on one tunnel, IPsec up (wrong peer ASN), held 3.5 min | 25 % of flows hit, ≤ 90 s, auto | **0 of 16 flows lost a packet.** The tunnel showed DOWN/0 routes on AWS within 93 s of the change; ECMP moved flows to the other 3 tunnels |
| Reset Azure gateway instance0 (2 of 4 tunnels) | 50 % of flows hit, ≤ 90 s, auto | **6 of 16 flows (38 %) had a 22–31 s gap**; 10 never dropped a packet. Full redundancy (4 tunnels UP with routes) took **14 min 20 s** |
| Path MTU | — | **1422 bytes** both ways (same as v1) |
| TCP MSS Azure → AWS | — | SYN sent with 1460, arrives with **1350** (the Azure VPN gateway's own clamp; tighter than the firewall's 1360) |
| TCP MSS AWS → Azure | — | host-a offered 1220, **1170** arrived. Lower than expected: needs follow-up |

## What this shows

- **A clean failure and a silent failure behave differently.** A config mismatch makes the peer
  reject the BGP OPEN with a NOTIFICATION, the routes are withdrawn at once, and ECMP rehashes
  before a 5/s probe notices. A gateway instance reboot gives no NOTIFICATION, so the flows on its
  tunnels wait for the BGP hold timer (about 30 s here).
- **Redundancy loss lasts far longer than the outage.** Users see a 30 s blip, but the link runs
  on 2 of 4 tunnels for about 14 minutes while the instance rebuilds its tunnels.
- **MindBridge AI's model was pessimistic in one case and incomplete in another.** It assumed the
  hold-timer recovery (90 s) for every BGP failure, and it had no "reduced-redundancy window".
  Both are now model inputs: clean withdrawal ≈ 0 s, silent failure ≈ hold time, and the
  rebuild window ≈ 15 min.

Raw data: `test3-paths.csv`, `test3-bgp-break*`, `test3-instance-down-instance0*`, `test3-mtu.txt`.
