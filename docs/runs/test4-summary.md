# Test 4: hub-and-spoke routing through the firewall (Session 1, 2026-11-23)

Path: Azure hub firewall → VPN → TGW (vpn table) → inspection VPC (fw-a in 2a / fw-b in 2b,
stateful nftables) → TGW (inspection table) → app spoke test hosts 10.10.0.10 (2a) and 10.10.0.74 (2b).
Probe: 200 short HTTP requests per host from the Azure firewall, each from its own source port.

| Step | MindBridge precheck | Measured |
|---|---|---|
| Baseline (appliance mode on) | — | **400/400 ok** |
| **Break A:** remove the app spoke's propagation into the inspection table | **BLOCK:** Azure→AWS broken, manual recovery | **0/100 once settled** (14–20 % got through in the first seconds while the change applied). Evidence: inspection table had 0 routes to 10.10.0.0/20; the firewalls' accept counters still grew (they forwarded the SYNs; the TGW dropped them) |
| Restore A | PASS | 87–95 % in the first seconds, **100/100** once settled |
| **Break B:** appliance mode off | **BLOCK:** 50 % degraded | **400/400 ok.** Flow logs: all 400 flows symmetric (request and reply on the same firewall) |
| Restore B: appliance mode back on | PASS | **22–40 % ok for several minutes.** The fw-invalid drop counters jumped (50→404 on fw-a, 39→364 on fw-b), and both firewalls held SYN_SENT [UNREPLIED] entries. **Back to 100 % within ~14 min**, without intervention |

## What this shows

- **Break A is the classic "everything looks healthy" outage.** Tunnels, BGP and the firewalls were
  all fine; one missing TGW route blackholed the traffic. The route tables found it in one
  command. MindBridge AI's pre-change check would have stopped the change before it was applied.
- **Appliance mode didn't matter for VPN↔VPC traffic in this topology.** The VPN attachment has no
  AZ, and the TGW hashed both directions of each flow onto the same inspection AZ. The textbook
  asymmetry needs VPC↔VPC traffic between AZ-pinned attachments (a second spoke VPC).
- **Changing appliance mode on live traffic is itself disruptive.** Turning it back on re-pinned
  existing hashing, and for up to ~14 minutes many new flows returned through the other firewall,
  which dropped them as invalid state. Treat the setting as "set at build time" and change it only
  in a maintenance window.
- **MindBridge AI was wrong about break B in both directions.** It predicted 50 % loss for "off"
  and nothing for "on". Its model now needs to scope appliance-mode risk to VPC↔VPC cross-AZ
  flows, and to treat a toggle as a transition risk.

Raw data: `test4-baseline.*`, `test4-break-a*`, `test4-break-b*` (including `test4-break-b-flows.csv`).
