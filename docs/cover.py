"""CloudBridge README cover , 2560 x 1280.

Regenerate:
    pip install diagrams
    cd docs && python3 cover.py && rsvg-convert cover.svg -o cover.png
"""

import base64
import pathlib

import diagrams

ICONS = pathlib.Path(diagrams.__file__).parent.parent / "resources"
OUT = pathlib.Path(__file__).with_name("cover.svg")
W, H = 2560, 1280
FONT = "Inter, Helvetica Neue, Helvetica, Arial, sans-serif"
AWS, AZURE, ACCENT = "#ff9900", "#2f8cff", "#38bdf8"
parts = []


def img(path, cx, cy, size):
    data = base64.b64encode((ICONS / f"{path}.png").read_bytes()).decode()
    parts.append(f'<image href="data:image/png;base64,{data}" x="{cx - size / 2}" y="{cy - size / 2}" '
                 f'width="{size}" height="{size}"/>')


def text(x, y, s, size, fill, weight=400, anchor="start", spacing=0):
    ls = f' letter-spacing="{spacing}"' if spacing else ""
    parts.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" font-weight="{weight}" '
                 f'text-anchor="{anchor}"{ls}>{s}</text>')


# ---------- background ----------
parts.append(f'<rect width="{W}" height="{H}" fill="#0b1220"/>')
for x in range(0, W, 64):
    parts.append(f'<line x1="{x}" y1="0" x2="{x}" y2="{H}" stroke="#ffffff" stroke-opacity="0.025"/>')
for y in range(0, H, 64):
    parts.append(f'<line x1="0" y1="{y}" x2="{W}" y2="{y}" stroke="#ffffff" stroke-opacity="0.025"/>')

# ---------- left: title block ----------
text(128, 172, "MULTI-CLOUD · HUB-AND-SPOKE · FAILURE ENGINEERING", 34, "#8ea3c4", 700, spacing=5)
text(120, 345, "CloudBridge", 156, "#ffffff", 800)
text(128, 440, "AWS + Azure, built in Terraform: tested under injected", 46, "#cdd7e6")
text(128, 504, "failures, measured, and explained from routing and DNS up.", 46, "#cdd7e6")
text(128, 600, "Jeevanandh Ravi · Cloud Network Engineer", 32, "#8ea3c4")

# ---------- right: diagram ----------
# DNS: two providers in one pill
parts.append('<rect x="1560" y="70" width="840" height="230" rx="28" fill="#121c30" stroke="#33415c" stroke-width="2"/>')
img("aws/network/route-53", 1720, 160, 112)
img("azure/network/dns-zones", 2060, 160, 104)
img("azure/network/traffic-manager-profiles", 2210, 160, 96)
text(1720, 258, "Route 53", 30, "#ffffff", 700, "middle")
text(2135, 258, "Azure DNS + Traffic Manager", 30, "#ffffff", 700, "middle")
text(1980, 340, "2 DNS providers · no single point of failure", 28, "#9fb1cc", 400, "middle")

# glows
parts.append(f'<circle cx="1620" cy="800" r="300" fill="url(#gA)"/>')
parts.append(f'<circle cx="2290" cy="800" r="300" fill="url(#gZ)"/>')

# DNS -> clouds
parts.append(f'<path d="M 1760 360 L 1760 420 L 1620 420 L 1620 600" fill="none" stroke="{AWS}" stroke-width="5"/>')
parts.append(f'<path d="M 2200 360 L 2200 420 L 2290 420 L 2290 600" fill="none" stroke="{AZURE}" stroke-width="5" stroke-dasharray="14 10"/>')
text(1600, 500, "PRIMARY", 26, "#cdd7e6", 600, "end")
text(2310, 500, "SECONDARY", 26, "#cdd7e6", 600, "start")

# AWS box
parts.append(f'<rect x="1440" y="600" width="360" height="330" rx="26" fill="#3a2a10" fill-opacity="0.75" stroke="{AWS}" stroke-width="4"/>')
img("aws/network/transit-gateway", 1620, 690, 118)
text(1620, 800, "AWS · hub &amp; spoke", 34, "#ffffff", 700, "middle")
text(1620, 845, "Transit GW · 2 firewalls", 26, "#e9d9bf", 400, "middle")
text(1620, 885, "EKS · ALB · us-east-2", 26, "#e9d9bf", 400, "middle")

# Azure box
parts.append(f'<rect x="2110" y="600" width="360" height="330" rx="26" fill="#0f2a52" fill-opacity="0.8" stroke="{AZURE}" stroke-width="4"/>')
img("azure/compute/kubernetes-services", 2290, 690, 118)
text(2290, 800, "Azure · hub &amp; spoke", 34, "#ffffff", 700, "middle")
text(2290, 845, "VPN GW ×2 · firewall VM", 26, "#c9dcf5", 400, "middle")
text(2290, 885, "AKS · Cilium · Chicago", 26, "#c9dcf5", 400, "middle")

# 4 tunnels
for i, y in enumerate((700, 716, 732, 748)):
    parts.append(f'<line x1="1800" y1="{y}" x2="2110" y2="{y}" stroke="url(#tun)" stroke-width="5"/>')
img("aws/network/site-to-site-vpn", 1955, 724, 84)
text(1955, 820, "IPsec ×4", 30, "#ffffff", 700, "middle")
text(1955, 858, "eBGP · ECMP", 26, "#cdd7e6", 400, "middle")

# ---------- bottom: measured results ----------
cards = [
    ("36.4 s", "DNS failover, Route 53 down", "304/304 lookups via Azure DNS"),
    ("41.7 s", "Region loss", "app + all 4 VPN tunnels cut"),
    ("0 / 16", "Flows lost on a BGP break", "ECMP moved them instantly"),
    ("9–14 min", "MindBridge AI early warning", "before loss crossed 5 %, 0 false alarms"),
]
x = 128
for big, title, sub in cards:
    parts.append(f'<rect x="{x}" y="1000" width="560" height="210" rx="22" fill="#121c30" stroke="#2b3954" stroke-width="2"/>')
    text(x + 36, 1092, big, 74, "#ffffff", 800)
    text(x + 36, 1148, title, 32, "#ffffff", 700)
    text(x + 36, 1188, sub, 27, "#9fb1cc")
    x += 600

defs = f'''<defs>
  <radialGradient id="gA"><stop offset="0" stop-color="{AWS}" stop-opacity="0.28"/><stop offset="1" stop-color="{AWS}" stop-opacity="0"/></radialGradient>
  <radialGradient id="gZ"><stop offset="0" stop-color="{AZURE}" stop-opacity="0.30"/><stop offset="1" stop-color="{AZURE}" stop-opacity="0"/></radialGradient>
  <linearGradient id="tun" gradientUnits="userSpaceOnUse" x1="1800" y1="0" x2="2110" y2="0"><stop offset="0" stop-color="{AWS}"/><stop offset="1" stop-color="{AZURE}"/></linearGradient>
</defs>'''
OUT.write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
               f'font-family="{FONT}">{defs}{"".join(parts)}</svg>')
print(f"wrote {OUT}")
