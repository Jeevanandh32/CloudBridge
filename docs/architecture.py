"""CloudBridge architecture diagram, hand-placed on a grid, with official AWS / Azure icons.

Layout:
- Left: users, the two DNS providers, and MindBridge AI.
- Top: AWS hub-and-spoke (inspection VPC + Transit Gateway + app spoke).
- Middle: the 4-tunnel VPN.
- Bottom: the Azure hub VNet peered to the AKS spoke.

Icons come from the `diagrams` package (official icon sets) and are embedded, so the SVG is
self-contained.

Regenerate:
    pip install diagrams
    cd docs && python3 architecture.py        -> architecture.svg
    rsvg-convert -z 2 architecture.svg -o architecture.png
"""

import base64
import pathlib

import diagrams

ICONS = pathlib.Path(diagrams.__file__).parent.parent / "resources"
OUT = pathlib.Path(__file__).with_name("architecture.svg")

W, H = 1900, 1275
AWS, AZURE, VPN, GREY, FW = "#ff9900", "#0078d4", "#16191f", "#545b64", "#c7254e"
parts = []


def icon(path, cx, cy, label, size=60):
    data = base64.b64encode((ICONS / f"{path}.png").read_bytes()).decode()
    half = size // 2
    parts.append(f'<image href="data:image/png;base64,{data}" x="{cx - half}" y="{cy - half}" '
                 f'width="{size}" height="{size}"/>')
    for i, line in enumerate(label.split("\n")):
        weight = ' font-weight="700"' if i == 0 else ""
        parts.append(f'<text x="{cx}" y="{cy + half + 16 + i * 14}" class="l"{weight}>{line}</text>')


def box(x, y, w, h, label, stroke, fill="#ffffff", dash=False, bold=False):
    d = ' stroke-dasharray="6 4"' if dash else ""
    parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{fill}" '
                 f'stroke="{stroke}" stroke-width="{2 if bold else 1.2}"{d}/>')
    parts.append(f'<text x="{x + 12}" y="{y + 20}" class="{"bh" if bold else "b"}">{label}</text>')


def arrow(d, color, label=None, at=None, dashed=False, width=2, head=True):
    dash = ' stroke-dasharray="7 5"' if dashed else ""
    mark = f' marker-end="url(#a-{color[1:]})"' if head else ""
    parts.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}"{dash}{mark}/>')
    if label:
        parts.append(f'<text x="{at[0]}" y="{at[1]}" class="e" fill="{color}">{label}</text>')


def note(x, y, text, cls="n"):
    for i, line in enumerate(text.split("\n")):
        parts.append(f'<text x="{x}" y="{y + i * 15}" class="{cls}">{line}</text>')


# ---------------- Left: users, DNS (two providers), MindBridge AI ----------------
icon("onprem/client/users", 80, 610, "Users\napp.jeevs.click")

box(170, 300, 260, 600, "DNS · 2 providers (no SPOF)", GREY, "#fafafa", bold=True)
icon("aws/network/route-53", 300, 400, "Route 53\nfailover records\nhealth checks 10 s × 3")
icon("azure/network/dns-zones", 300, 590, "Azure DNS\napp → CNAME")
icon("azure/network/traffic-manager-profiles", 300, 760, "Traffic Manager\npriority · /health 10 s\nTTL 30")
arrow("M 300 640 L 300 718", AZURE, width=1.5)
note(185, 865, "Registrar NS: 2 Route 53 + 2 Azure\nRoute 53 unreachable → Azure answers")
arrow("M 112 600 L 262 410", GREY, width=1.5)
arrow("M 112 615 L 262 590", GREY, width=1.5)

box(40, 940, 390, 250, "MindBridge AI · laptop · read-only", "#6f42c1", "#f7f2ff", bold=True)
icon("programming/language/python", 110, 1020, "precheck\nwhat-if · predict", size=52)
note(175, 1000, "Blocks risky terraform plans\n(stopped both Test 4 breaks)\nN-1 what-if: single points of failure\nPredict: warned 9–14 min before\nloss crossed 5 %, 0 false alarms\nReads AWS/Azure APIs, SSM,\nrun-command, kubectl", "nm")

# ---------------- AWS (top) ----------------
box(470, 60, 1400, 480, "AWS · us-east-2 (Ohio) · hub and spoke", AWS, "#fff7eb", bold=True)

box(490, 95, 440, 420, "Inspection VPC 10.10.240.0/24 · 2 AZs", AWS)
icon("aws/network/internet-gateway", 710, 150, "", size=50)
note(745, 155, "Internet gateway", "nm")
icon("aws/compute/ec2", 600, 290, "fw-a · 2a\nnftables · NAT\nMSS clamp · dnsmasq")
icon("aws/compute/ec2", 820, 290, "fw-b · 2b\nnftables · NAT\nMSS clamp · dnsmasq")
icon("aws/storage/simple-storage-service-s3", 710, 445, "Flow logs → S3", size=46)
arrow("M 610 255 L 688 176", FW, width=1.5)
arrow("M 810 255 L 732 176", FW, width=1.5)

icon("aws/network/transit-gateway", 1030, 430, "Transit Gateway\nASN 64512 · ECMP\nspokes / vpn / inspection RTs", size=64)
arrow("M 990 420 L 860 320", FW, width=2)
arrow("M 990 435 L 640 320", FW, width=2)

box(1110, 95, 740, 420, "App spoke VPC 10.10.0.0/20 · pods 10.10.64.0/18", AWS)
icon("aws/network/elb-application-load-balancer", 1190, 190, "ALB (public)\nIP targets")
icon("k8s/compute/pod", 1370, 190, "frontend ×3")
icon("k8s/compute/pod", 1530, 190, "backend ×3")
icon("aws/network/privatelink", 1740, 190, "S3 interface endpoint\n(PrivateLink, 1 AZ)")
icon("aws/compute/elastic-kubernetes-service", 1370, 380, "EKS 1.35 · 2 × t3.medium Spot\nVPC CNI · prefix + custom net.\nNetworkPolicy")
icon("aws/network/route-53-hosted-zone", 1740, 380, "Private zone\ncloudbridge.internal")
arrow("M 1222 190 L 1335 190", AWS)
arrow("M 1405 190 L 1495 190", AWS)
arrow("M 1150 470 L 1068 440", FW, "all egress → TGW → firewalls", (1220, 492), width=2)

# ---------------- VPN (middle) ----------------
icon("aws/network/site-to-site-vpn", 1030, 612, "", size=60)
note(1075, 598, "2 VPN connections · 4 IPsec IKEv2 tunnels", "vh")
note(1075, 616, "eBGP 64512 ↔ 65515 · ECMP both ways · ~12 ms RTT", "v")
note(1075, 633, "MSS clamped to 1350 (Azure gateway) · path MTU 1422", "v")
for dx in (-12, -4, 4, 12):
    arrow(f"M {1030 + dx} 514 L {1030 + dx} 580", VPN, width=2, head=False)
    arrow(f"M {1030 + dx} 644 L {1030 + dx} 760", VPN, width=2, head=False)

# ---------------- Azure (bottom) ----------------
box(470, 690, 1400, 500, "Azure · northcentralus (Chicago) · hub and spoke", AZURE, "#eef6fd", bold=True)

box(490, 725, 580, 445, "Hub VNet 10.20.240.0/22", AZURE)
icon("azure/network/public-ip-addresses", 580, 800, "Public IP + DNS label\n(firewall)", size=50)
icon("azure/network/virtual-network-gateways", 1030, 800, "VPN gateway\nactive-active · 2 instances\nVpnGw1AZ · ASN 65515", size=56)
icon("azure/compute/vm", 580, 975, "fw VM · nftables\nDNAT → ILB + SNAT\nSNAT egress · dnsmasq")
icon("azure/network/dns-private-zones", 830, 975, "Private DNS zones\naz.cloudbridge.internal\nprivatelink.blob")
arrow("M 580 862 L 580 940", FW, width=2)

arrow("M 1070 960 L 1150 960", AZURE, width=3, head=False)
note(1078, 948, "peering", "e2")

box(1150, 725, 700, 445, "AKS spoke VNet 10.20.0.0/20 · UDR 0/0 → hub firewall", AZURE)
icon("azure/network/load-balancers", 1240, 830, "Internal LB\n10.20.4.10", size=54)
icon("k8s/compute/pod", 1410, 830, "frontend ×3")
icon("k8s/compute/pod", 1560, 830, "backend ×3")
icon("azure/network/private-endpoint", 1750, 830, "Private Endpoint\nBlob (10.20.5.4)", size=54)
icon("azure/compute/kubernetes-services", 1410, 1020, "AKS 1.35 Free · 1 × B2als_v2\nAzure CNI Overlay + Cilium\npods 10.244.0.0/16 (SNAT)")
icon("azure/storage/storage-accounts", 1750, 1020, "Storage\nflow logs · probe blob", size=50)
arrow("M 580 1058 L 580 1140 L 1180 1140 L 1180 830 L 1209 830", FW, "DNAT → ILB", (880, 1132), width=2.5)
arrow("M 1268 830 L 1375 830", AZURE)
arrow("M 1445 830 L 1525 830", AZURE)

# ---------------- DNS answers ----------------
arrow("M 332 400 L 450 400 L 450 40 L 1085 40 L 1085 190 L 1156 190", AWS, "PRIMARY / priority 1 → ALB", (770, 32), width=3)
arrow("M 332 770 L 450 770 L 450 800 L 551 800", AZURE, "SECONDARY / priority 2", (404, 792), dashed=True, width=3)

# ---------------- Legend ----------------
parts.append('<text x="470" y="1214" class="g">Orange: AWS user path · Blue: Azure user path · Red: through a firewall · '
             'Black: 4 IPsec/BGP tunnels · Purple: MindBridge AI (reads only, never changes anything)</text>')

markers = "".join(
    f'<marker id="a-{c[1:]}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
    f'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker>'
    for c in (AWS, AZURE, VPN, GREY, FW)
)
svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}"
     font-family="Segoe UI, Helvetica Neue, Helvetica, Arial, sans-serif">
<defs>{markers}<style>
  .t {{ font-size: 26px; font-weight: 700; fill: #16191f; }}
  .l {{ font-size: 12px; fill: #16191f; text-anchor: middle; }}
  .b {{ font-size: 12px; fill: #545b64; }}
  .bh {{ font-size: 16px; font-weight: 700; fill: #16191f; }}
  .e {{ font-size: 12px; font-weight: 700; text-anchor: middle; paint-order: stroke; stroke: #ffffff; stroke-width: 5px; }}
  .e2 {{ font-size: 12px; font-weight: 700; fill: #0078d4; }}
  .vh {{ font-size: 14px; font-weight: 700; fill: #16191f; }}
  .v {{ font-size: 12px; fill: #16191f; }}
  .n {{ font-size: 11.5px; fill: #545b64; }}
  .nm {{ font-size: 12px; fill: #16191f; }}
  .g {{ font-size: 12px; fill: #545b64; }}
</style></defs>
<rect width="{W}" height="{H}" fill="#ffffff"/>
<text x="40" y="42" class="t">CloudBridge: hub-and-spoke on AWS + Azure, DNS with no single point of failure</text>
<g transform="translate(0,45)">
{chr(10).join(parts)}
</g>
</svg>
"""
OUT.write_text(svg)
print(f"wrote {OUT}")
