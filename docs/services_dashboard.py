"""CloudBridge: services in use, with approximate on-demand cost while running.

Prices: us-east-2 / northcentralus on-demand list prices, checked 2026-11-23. The Azure VM and
VPN gateway prices came from the Azure retail price API; Spot prices vary.

Regenerate:
    cd docs && python3 services_dashboard.py      -> services-dashboard.svg
"""

import pathlib
from html import escape

OUT = pathlib.Path(__file__).with_name("services-dashboard.svg")
W, H = 1600, 1200
NET, CMP, TRF, REG, ST = "#8b5cf6", "#22a355", "#0d9e8f", "#5b6785", "#a0652d"
AWS, AZ = "#ff9900", "#0078d4"
parts = []


def t(x, y, s, size=13, fill="#1f2937", weight=400, anchor="start"):
    parts.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" font-weight="{weight}" '
                 f'text-anchor="{anchor}">{escape(s)}</text>')


def card(x, y, badge, color, title, cost, l1, l2, w=332, h=82):
    parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="#ffffff" stroke="#e5e7eb"/>')
    parts.append(f'<rect x="{x + 14}" y="{y + 18}" width="50" height="46" rx="6" fill="{color}"/>')
    t(x + 39, y + 46, badge, 12 if len(badge) < 5 else 10, "#ffffff", 700, "middle")
    t(x + 76, y + 27, title, 16, "#111827", 700)
    free = cost in ("free", "included") or cost.startswith("$0 ")
    t(x + w - 14, y + 27, cost, 12.5, "#16a34a" if free else ("#374151" if "mo" in cost or "day" in cost else "#dc2626"), 700, "end")
    t(x + 76, y + 48, l1, 12.5, "#4b5563")
    t(x + 76, y + 66, l2, 12.5, "#4b5563")


def panel(x, y, w, h, color, title, cost):
    parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="#f9fafb" stroke="{color}" stroke-width="2.5"/>')
    parts.append(f'<path d="M {x} {y + 12} a 12 12 0 0 1 12 -12 h {w - 24} a 12 12 0 0 1 12 12 v 38 h {-w} z" fill="{color}"/>')
    t(x + 20, y + 33, title, 21, "#ffffff", 700)
    t(x + w - 20, y + 32, cost, 13, "#ffffff", 400, "end")


parts.append(f'<rect width="{W}" height="{H}" fill="#f3f4f6"/>')
t(34, 48, "CloudBridge: services in use", 30, "#111827", 700)
t(34, 76, "Hub-and-spoke on AWS + Azure, all built with Terraform · approximate on-demand rates while running · "
          "every layer destroyed after each test session", 15, "#4b5563")

# ---------- DNS banner ----------
parts.append('<rect x="34" y="98" width="1532" height="112" rx="12" fill="#ffffff" stroke="#8b5cf6" stroke-width="2.5"/>')
parts.append(f'<rect x="54" y="120" width="62" height="62" rx="8" fill="{TRF}"/>')
t(85, 157, "DNS", 13, "#ffffff", 700, "middle")
t(136, 134, "DNS on 2 providers: no single point of failure for app.jeevs.click", 17, "#111827", 700)
t(136, 158, "Route 53: failover records (PRIMARY alias → ALB, SECONDARY → Azure firewall), 2 health checks on deep /health, "
            "10 s × 3 · Azure DNS: app → CNAME → Traffic Manager (priority, /health every 10 s, TTL 30)", 12.5, "#4b5563")
t(136, 180, "Registrar delegates to 2 Route 53 + 2 Azure name servers (auto-renew off) · tested: with Route 53 "
            "unreachable, Azure DNS answered 304 of 304 lookups and failover took 36.4 s", 12.5, "#4b5563")
t(1546, 134, "≈ $3/mo + $3/yr domain", 13, "#8b5cf6", 700, "end")

# ---------- AWS panel ----------
PX, PY, PW, PH = 34, 230, 710, 755
panel(PX, PY, PW, PH, AWS, "AWS · us-east-2 (Ohio)", "≈ $0.49/hr running")
aws = [
    ("TGW", NET, "Transit Gateway", "$0.20/hr", "4 attachments × $0.05 · ASN 64512", "3 route tables · ECMP for the VPN"),
    ("VPN", NET, "Site-to-Site VPN ×2", "$0.10/hr", "4 tunnels → 2 Azure gateway instances", "on the TGW · eBGP · ECMP"),
    ("VPC", NET, "Inspection VPC", "free", "10.10.240.0/24 across 2 AZs", "IGW for firewall egress NAT"),
    ("FW", NET, "Firewalls fw-a / fw-b", "≈ $0.008/hr", "2 × t4g.nano · stateful nftables", "NAT · MSS clamp · dnsmasq DNS"),
    ("VPC", NET, "App spoke VPC", "free", "10.10.0.0/20 + 10.10.64.0/18 (pods)", "/26 node subnets · /19 pod subnets"),
    ("IPv4", NET, "Public IPv4 ×4", "$0.02/hr", "2 firewalls + 2 ALB nodes", "$0.005/hr each since 2024"),
    ("EKS", CMP, "EKS cluster 1.35", "$0.10/hr", "VPC CNI · built-in NetworkPolicy", "prefix delegation + custom networking"),
    ("EC2", CMP, "Spot node group", "≈ $0.03/hr", "2 × t3.medium / t3a.medium", "Spot: about 70 % below on-demand"),
    ("ALB", TRF, "Application LB", "≈ $0.023/hr", "public · IP targets · HC /live", "created by the LB Controller"),
    ("EP", TRF, "S3 endpoints", "$0.01/hr", "interface (PrivateLink, 1 AZ)", "+ gateway endpoint (free)"),
    ("R53", TRF, "Route 53 private zone", "$0.50/mo", "cloudbridge.internal", "shared with the inspection VPC"),
    ("ECR", REG, "ECR repository", "cents/mo", "cloudbridge-app image", "in-region pulls, no cross-cloud dependency"),
    ("S3", ST, "Flow logs + state", "cents/mo", "VPC flow logs → S3 (7-day expiry)", "Terraform state: versioned, encrypted"),
    ("COST", ST, "Budget + alarms", "free", "$15 budget (60 / 100 %)", "VPN alarms → CloudWatch + SNS"),
]
for i, c in enumerate(aws):
    card(PX + 16 + (i % 2) * 346, PY + 66 + (i // 2) * 96, *c)

# ---------- Azure panel ----------
ZX = 856
panel(ZX, PY, PW, PH, AZ, "Azure · northcentralus (Chicago)", "≈ $0.31/hr running")
azure = [
    ("VPNG", NET, "VPN gateway", "$0.21/hr", "VpnGw1AZ · active-active, 2 instances", "ASN 65515 · 25–30 min to build"),
    ("PIP", NET, "Public IPs ×3", "$0.015/hr", "2 VPN instances + firewall (DNS label)", "= the subscription's limit of 3"),
    ("VNET", NET, "Hub VNet", "free", "10.20.240.0/22", "GatewaySubnet + firewall subnet"),
    ("VM", NET, "Firewall VM", "$0.009/hr", "B2ats_v2 · nftables", "DNAT + SNAT in · SNAT out · dnsmasq"),
    ("VNET", NET, "AKS spoke VNet", "free", "10.20.0.0/20 · peered, gateway transit", "UDR 0.0.0.0/0 → hub firewall"),
    ("LNG", NET, "VPN connections ×4", "included", "+ 4 local network gateways", "IKEv2 · PSK · BGP · custom APIPA"),
    ("AKS", CMP, "AKS cluster 1.35", "$0 (Free tier)", "Azure CNI Overlay + Cilium", "outbound through the firewall (UDR)"),
    ("VMSS", CMP, "Node pool", "$0.038/hr", "1 × B2als_v2 (2 vCPU / 4 GB)", "regional vCPU quota: 4 of 6 used"),
    ("LB", TRF, "Internal LB", "≈ $0.025/hr", "10.20.4.10 · created by AKS", "reached through the firewall's DNAT"),
    ("PE", TRF, "Private Endpoint", "$0.01/hr", "Blob storage at 10.20.5.4", "privatelink.blob DNS zone"),
    ("DNS", TRF, "Private DNS zones ×2", "cents/mo", "az.cloudbridge.internal", "privatelink.blob.core.windows.net"),
    ("ACR", REG, "Container Registry", "$0.17/day", "Basic · AcrPull for the kubelet", "in-region pulls"),
    ("ST", ST, "Storage account", "cents/mo", "VNet flow logs + probe blob", "7-day retention"),
    ("COST", ST, "Budget", "free", "$10 budget", "alerts at 60 % / 100 %"),
]
for i, c in enumerate(azure):
    card(ZX + 16 + (i % 2) * 346, PY + 66 + (i // 2) * 96, *c)

# ---------- VPN connector ----------
for y, col in ((506, AWS), (522, AWS), (538, AZ), (554, AZ)):
    parts.append(f'<line x1="726" y1="{y}" x2="872" y2="{y}" stroke="#111827" stroke-width="2.2"/>')
    parts.append(f'<circle cx="799" cy="{y}" r="4" fill="{col}"/>')
parts.append('<rect x="748" y="575" width="102" height="122" rx="6" fill="#ffffff" stroke="#111827"/>')
for i, (s, w) in enumerate((("IPsec IKEv2", 700), ("4 tunnels", 400), ("eBGP", 700), ("64512 ↔ 65515", 400), ("ECMP", 700), ("~12 ms RTT", 700))):
    t(799, 594 + i * 18, s, 12, "#111827", w, "middle")

# ---------- bottom boxes ----------
def box(x, title, lines, w=496):
    parts.append(f'<rect x="{x}" y="1005" width="{w}" height="170" rx="10" fill="#ffffff" stroke="#e5e7eb"/>')
    t(x + 20, 1032, title, 15, "#111827", 700)
    for i, s in enumerate(lines):
        t(x + 20, 1058 + i * 22, s, 13, "#4b5563")


box(34, "Running cost (everything up)", [
    "AWS ≈ $0.49/hr · Azure ≈ $0.31/hr · total ≈ $0.80/hr",
    "Biggest: VPN GW $0.21 · TGW $0.20 · EKS $0.10 · AWS VPN $0.10",
    "Same design with managed firewalls, NAT gateways and",
    "DNS resolvers: ≈ $2.50–3.00/hr",
    "Total across 3 test sessions: ≈ $7, destroyed after each",
])
box(552, "Measured", [
    "Route 53 unreachable: 304/304 lookups via Azure DNS · failover 36.4 s",
    "Region loss (app + all 4 tunnels): users on Azure in 41.7 s",
    "BGP config break: 0 of 16 flows lost · gateway reset: 22–31 s pauses",
    "Pod IPs: 18 → 204 pods with custom networking",
    "MindBridge AI: warned 9–14 min before loss crossed 5 %",
], w=496)
parts.append('<rect x="1070" y="1005" width="496" height="170" rx="10" fill="#ffffff" stroke="#e5e7eb"/>')
t(1090, 1032, "Legend", 15, "#111827", 700)
for i, (c, s) in enumerate(((NET, "Network"), (CMP, "Compute / Kubernetes"), (TRF, "Traffic / DNS"),
                             (REG, "Registry"), (ST, "State / governance / cost"))):
    x, y = 1090 + (i % 3) * 165, 1050 + (i // 3) * 26
    parts.append(f'<rect x="{x}" y="{y}" width="14" height="14" rx="3" fill="{c}"/>')
    t(x + 22, y + 12, s, 13, "#374151")
t(1090, 1124, "$/hr", 13, "#dc2626", 700)
t(1126, 1124, "bills hourly ·", 13, "#4b5563")
t(1218, 1124, "free / included", 13, "#16a34a", 700)
t(1320, 1124, "no extra charge", 13, "#4b5563")
t(1090, 1150, "Firewalls are Linux VMs instead of managed firewalls (~$0.40–1.25/hr each).", 12.5, "#4b5563")

OUT.write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
               f'font-family="Inter, Helvetica Neue, Helvetica, Arial, sans-serif">{"".join(parts)}</svg>')
print(f"wrote {OUT}")
