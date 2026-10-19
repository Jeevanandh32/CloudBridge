"""CloudBridge architecture diagram, hand-placed on a grid, with official AWS / Azure icons.

Layout: users and Route 53 on the left (middle), AWS on top, Azure at the bottom, and the
site-to-site VPN between them. Icons come from the `diagrams` package (official icon sets)
and are embedded, so the SVG is self-contained.

Regenerate:
    pip install diagrams
    cd docs && python3 architecture.py        -> architecture.svg
"""

import base64
import pathlib

import diagrams

ICONS = pathlib.Path(diagrams.__file__).parent.parent / "resources"
OUT = pathlib.Path(__file__).with_name("architecture.svg")

W, H = 1800, 1140
AWS, AZURE, VPN, GREY = "#ff9900", "#0078d4", "#16191f", "#545b64"
parts = []


def icon(path, cx, cy, label, size=64):
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


# ---------------- Left: users and global DNS ----------------
icon("onprem/client/users", 100, 580, "Users\n1 req/s probe")
icon("aws/network/route-53", 290, 580, "Route 53\napp.jeevs.click\nhealth checks /health\n10 s × 3")
arrow("M 135 580 L 250 580", GREY)

# ---------------- AWS (top) ----------------
box(420, 60, 1340, 440, "AWS · us-east-2 (Ohio)", AWS, "#fff7eb", bold=True)
box(440, 95, 1000, 385, "VPC 10.10.0.0/16 · 2 AZs", AWS)
box(460, 130, 200, 330, "Public subnets /24 ×2", "#8c4fff", "#f6f2ff")
icon("aws/network/internet-gateway", 560, 180, "Internet gateway")
icon("aws/network/elb-application-load-balancer", 560, 290, "ALB (public)\nIP targets · HC /live")
icon("aws/network/nat-gateway", 560, 392, "NAT gateway\nsingle (cost)")

box(680, 130, 740, 330, "Private subnets /19 ×2 · EKS 1.35 · 2 × t3.medium · VPC CNI", "#8c4fff", "#f6f2ff")
icon("k8s/compute/pod", 770, 230, "frontend ×3")
icon("aws/network/elb-network-load-balancer", 990, 230, "NLB (internal)")
icon("k8s/compute/pod", 1210, 230, "backend ×3")
icon("aws/network/route-53-hosted-zone", 1350, 230, "Private zone\ncloudbridge.internal")
icon("aws/compute/elastic-kubernetes-service", 770, 370, "EKS control plane")
icon("aws/compute/ec2", 990, 370, "Managed node group\n2 × t3.medium")

box(1460, 95, 280, 385, "Supporting services", GREY, "#ffffff", dash=True)
icon("aws/compute/ec2-container-registry", 1600, 165, "ECR\napp image")
icon("aws/security/identity-and-access-management-iam-role", 1600, 280, "IAM role\nLB Controller (Pod Identity)")
icon("aws/storage/simple-storage-service-s3", 1600, 395, "S3\nTerraform state")

# AWS request path
arrow("M 592 290 L 730 230", AWS)                                    # ALB -> frontend
arrow("M 805 230 L 950 230", AWS)                                    # frontend -> NLB
arrow("M 1025 230 L 1170 230", AWS)                                  # NLB -> backend
arrow("M 770 196 C 770 172, 1350 172, 1350 192", AWS, "resolves backend.cloudbridge.internal",
      (1060, 176), dashed=True, width=1.5)

# ---------------- VPN (middle) ----------------
icon("aws/network/vpn-gateway", 1090, 480, "", size=56)
parts.append('<text x="1128" y="485" class="vh">VGW · ASN 64512</text>')
icon("aws/network/site-to-site-vpn", 1090, 580, "", size=64)
parts.append('<text x="1135" y="568" class="vh">Site-to-Site VPN</text>')
parts.append('<text x="1135" y="586" class="v">IPsec IKEv2 × 2 tunnels · eBGP 64512 ↔ 65515</text>')
parts.append('<text x="1135" y="604" class="v">169.254.21.0/30, 169.254.22.0/30 · ~12 ms RTT</text>')
arrow("M 1082 508 L 1082 548", VPN, width=3, head=False)
arrow("M 1098 508 L 1098 548", VPN, width=3, head=False)
arrow("M 1082 612 L 1082 732", VPN, width=3, head=False)
arrow("M 1098 612 L 1098 732", VPN, width=3, head=False)

# ---------------- Azure (bottom) ----------------
box(420, 660, 1340, 440, "Azure · northcentralus (Chicago)", AZURE, "#eef6fd", bold=True)
box(440, 695, 1000, 385, "VNet 10.20.0.0/16 · cloudbridge-rg", AZURE)
box(460, 730, 200, 330, "Public entry", "#0f9d9a", "#eefaf9")
icon("azure/network/public-ip-addresses", 560, 800, "Static public IP")
icon("azure/network/load-balancers", 560, 940, "Standard LB (public)\nprobe /live")

box(980, 718, 440, 120, "GatewaySubnet 10.20.255.0/27", "#8c4fff", "#f6f2ff")
icon("azure/network/virtual-network-gateways", 1090, 772, "VPN gateway\nVpnGw1AZ · ASN 65515", size=56)
icon("azure/network/local-network-gateways", 1230, 772, "Local network\ngateways ×2", size=56)
icon("azure/network/connections", 1360, 772, "Connections ×2\nIKEv2 + BGP", size=56)

box(680, 855, 740, 205, "aks-nodes /22 · aks-pods /19 · AKS 1.35 Free · 2 × B2als_v2 · Azure CNI",
    "#8c4fff", "#f6f2ff")
icon("k8s/compute/pod", 770, 935, "frontend ×3")
icon("k8s/compute/pod", 990, 935, "backend ×3")
icon("azure/compute/kubernetes-services", 1210, 935, "AKS control plane")
icon("azure/compute/vm-scale-sets", 1350, 935, "System node pool\n2 × B2als_v2")

box(1460, 695, 280, 385, "Supporting services", GREY, "#ffffff", dash=True)
icon("azure/compute/container-registries", 1600, 800, "ACR\napp image")
icon("azure/identity/managed-identities", 1600, 940, "Managed identity\nAcrPull · Network Contrib.")

# Azure request path
arrow("M 560 856 L 560 900", AZURE)                                  # public IP -> LB
arrow("M 592 940 L 730 935", AZURE)                                  # LB -> frontend
arrow("M 805 935 L 950 935", AZURE, "Kubernetes Service", (878, 922))  # frontend -> backend

# ---------------- Route 53 failover ----------------
arrow("M 322 560 C 420 480, 430 300, 524 290", AWS, "PRIMARY", (345, 455), width=3)
arrow("M 322 600 C 420 680, 430 800, 524 800", AZURE, "SECONDARY", (345, 720), dashed=True, width=3)

# ---------------- Legend ----------------
parts.append('<text x="40" y="1128" class="g">Orange: AWS request path · Blue: Azure request path · '
             'Black: IPsec/BGP between the clouds · Dashed boxes: supporting services outside the VNet/VPC</text>')

markers = "".join(
    f'<marker id="a-{c[1:]}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
    f'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{c}"/></marker>'
    for c in (AWS, AZURE, VPN, GREY)
)
svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}"
     font-family="Segoe UI, Helvetica Neue, Helvetica, Arial, sans-serif">
<defs>{markers}<style>
  .t {{ font-size: 26px; font-weight: 700; fill: #16191f; }}
  .l {{ font-size: 12px; fill: #16191f; text-anchor: middle; }}
  .b {{ font-size: 12px; fill: #545b64; }}
  .bh {{ font-size: 16px; font-weight: 700; fill: #16191f; }}
  .e {{ font-size: 12px; font-weight: 700; text-anchor: middle; paint-order: stroke; stroke: #ffffff; stroke-width: 5px; }}
  .vh {{ font-size: 14px; font-weight: 700; fill: #16191f; }}
  .v {{ font-size: 12px; fill: #16191f; }}
  .g {{ font-size: 12px; fill: #545b64; }}
</style></defs>
<rect width="{W}" height="{H}" fill="#ffffff"/>
<text x="40" y="42" class="t">CloudBridge — AWS + Azure with Route 53 failover</text>
{chr(10).join(parts)}
</svg>
"""
OUT.write_text(svg)
print(f"wrote {OUT}")
