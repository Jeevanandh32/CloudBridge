"""Predict-mode collectors: a registry of read-only probes.

Every collector returns timestamped samples (signal, component, value, unit, ts). A collector
whose CLI is missing, whose target is not deployed, or that runs out of time is recorded as
"unavailable" with a short reason instead of failing the run.

Read-only, with two notes:
- aws_firewalls uses `aws ssm send-command` (AWS-RunShellScript) with a script that only reads
  counters. It changes nothing on the instance, but SSM keeps a command-invocation record.
- azure_firewall uses `az vm run-command invoke` the same way (also logged in the Activity Log).

`describe-vpn-connections` returns the tunnels' pre-shared keys; every call here uses a narrow
--query so they are never printed, parsed or stored. Error text is scrubbed of account and
subscription ids before it is stored.
"""
from __future__ import annotations

import fnmatch
import ipaddress
import json
import re
import shutil
import subprocess
import time
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable

from .detect import Sample


class Unavailable(Exception):
    """The target or the CLI is not there. Not an error: recorded and skipped."""


@dataclass
class Collector:
    name: str
    fn: Callable
    needs: tuple[str, ...]
    signals: tuple[str, ...]
    doc: str


REGISTRY: dict[str, Collector] = {}


def collector(name: str, needs: tuple[str, ...], signals: tuple[str, ...]):
    def deco(fn):
        REGISTRY[name] = Collector(name, fn, needs, signals, (fn.__doc__ or "").strip().splitlines()[0])
        return fn
    return deco


_SCRUB = [
    (re.compile(r"arn:aws[\w-]*:[^\s\"']+"), "<arn>"),
    (re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I), "<guid>"),
    (re.compile(r"\b\d{12}\b"), "<account>"),
    (re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+"), "<email>"),
    (re.compile(r"/subscriptions/[^\s/\"']+"), "/subscriptions/<id>"),
]


def scrub(text: str) -> str:
    for rx, rep in _SCRUB:
        text = rx.sub(rep, text)
    return text


def short_reason(stderr: str) -> str:
    s = stderr or ""
    low = s.lower()
    if "unable to locate credentials" in low or "expiredtoken" in low or "token has expired" in low \
            or "please run 'az login'" in low or "az login" in low and "error" in low:
        return "not logged in or credentials expired"
    for key in ("ResourceGroupNotFound", "ResourceNotFound", "NotFound", "was not found", "could not be found",
                "does not exist", "NoSuchEntity", "InvalidInstanceId", "is not registered", "No budget found",
                "budget doesn't exist"):
        if key.lower() in low:
            line = next((ln for ln in s.splitlines() if key.lower() in ln.lower()), key)
            return "not deployed: " + scrub(line.strip())[:160]
    if "connection refused" in low or "no such host" in low or "i/o timeout" in low \
            or "unable to connect to the server" in low:
        return "cluster unreachable (not deployed or endpoint gone)"
    first = next((ln.strip() for ln in s.splitlines() if ln.strip()), "command failed")
    return scrub(first)[:200]


@dataclass
class Ctx:
    targets: dict
    timeout_s: float
    now: float = field(default_factory=time.time)
    notes: list = field(default_factory=list)

    def __post_init__(self):
        self.deadline = time.monotonic() + self.timeout_s

    def remaining(self) -> float:
        return self.deadline - time.monotonic()

    def run(self, args: list[str], parse_json: bool = True, timeout: float | None = None):
        left = self.remaining()
        if left <= 1:
            raise Unavailable(f"timed out after {self.timeout_s:g} s")
        t = min(left, timeout) if timeout else left
        try:
            p = subprocess.run(args, capture_output=True, text=True, timeout=t,
                               env=_env(), stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            raise Unavailable(f"{args[0]} {args[1] if len(args) > 1 else ''} timed out after {t:.0f} s")
        except FileNotFoundError:
            raise Unavailable(f"{args[0]} CLI not installed")
        if p.returncode != 0:
            raise Unavailable(short_reason(p.stderr or p.stdout))
        out = p.stdout.strip()
        if not parse_json:
            return out
        if not out:
            return None
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            raise Unavailable(f"unexpected output from {args[0]}")

    def aws(self, *args, region: str | None = None, **kw):
        return self.run(["aws", *args, "--region", region or self.targets["aws_region"],
                         "--output", "json", "--no-cli-pager"], **kw)

    def az(self, *args, **kw):
        return self.run(["az", *args, "-o", "json", "--only-show-errors"], **kw)

    def sample(self, signal, component, value, unit="", detail="", ts=None) -> Sample:
        return Sample(float(ts if ts is not None else self.now), signal, component, float(value), unit, detail)


def _env():
    import os
    env = dict(os.environ)
    env["AWS_PAGER"] = ""
    env["AZURE_CORE_NO_COLOR"] = "1"
    return env


@dataclass
class RunResult:
    collector: str
    status: str      # ok | partial | unavailable | error
    message: str
    samples: list
    duration_s: float


def run_collector(c: Collector, targets: dict, timeout_s: float, now: float | None = None) -> RunResult:
    t0 = time.monotonic()
    missing = [n for n in c.needs if shutil.which(n) is None]
    if missing:
        return RunResult(c.name, "unavailable", f"{', '.join(missing)} CLI not installed", [], 0.0)
    ctx = Ctx(targets, timeout_s, now or time.time())
    try:
        samples = c.fn(ctx) or []
    except Unavailable as e:
        return RunResult(c.name, "unavailable", str(e), [], round(time.monotonic() - t0, 2))
    except Exception as e:  # a parsing bug must not stop the other collectors
        return RunResult(c.name, "error", scrub(f"{type(e).__name__}: {e}")[:200], [], round(time.monotonic() - t0, 2))
    status = "partial" if ctx.notes and samples else ("unavailable" if ctx.notes else "ok")
    return RunResult(c.name, status, "; ".join(ctx.notes)[:400], samples, round(time.monotonic() - t0, 2))


# ====================================================================== AWS subnets

# Prefix delegation hands each ENI slot an aligned /28 (16 contiguous addresses on a /28
# boundary). A subnet can show plenty of free IPs and still have no whole /28 left: Session 2
# saw "failed to assign an IP address" in /26 node subnets with 34-49 IPs free. So in prefix
# mode the binding resource is free aligned /28 blocks, not free IPs.

def aws_reserved(cidr: str) -> list[str]:
    """The 5 addresses AWS reserves in every subnet: the first 4 and the last."""
    net = ipaddress.ip_network(cidr, strict=False)
    return [str(net.network_address + i) for i in range(4)] + [str(net.broadcast_address)]


def free_aligned_blocks(cidr: str, used_ips, used_prefixes=(), prefix_len: int = 28) -> int:
    """How many prefix_len-aligned blocks of `cidr` are completely free.

    used_ips: every private IP in use (ENI primary and secondary IPs). used_prefixes: every
    delegated prefix (Ipv4Prefixes, any length). The AWS-reserved addresses always count as
    used, so the first and last block of a subnet can never be delegated: a /26 holds 4
    aligned /28s, of which at most 2 can ever be free.
    """
    net = ipaddress.ip_network(cidr, strict=False)
    if net.prefixlen > prefix_len:
        return 0
    size = 2 ** (32 - prefix_len)
    base = int(net.network_address)
    total = net.num_addresses // size
    taken: set[int] = set()

    def mark(lo: int, hi: int):
        lo, hi = max(lo, base), min(hi, base + net.num_addresses - 1)
        if lo <= hi:
            taken.update(range((lo - base) // size, (hi - base) // size + 1))

    for ip in list(used_ips) + aws_reserved(cidr):
        a = int(ipaddress.ip_address(ip))
        mark(a, a)
    for p in used_prefixes:
        pn = ipaddress.ip_network(p, strict=False)
        mark(int(pn.network_address), int(pn.broadcast_address))
    return total - len(taken)


def free_ip_count(cidr: str, used_ips, used_prefixes=()) -> int:
    """Free addresses the way AvailableIpAddressCount counts them (for tests and details)."""
    net = ipaddress.ip_network(cidr, strict=False)
    used = {str(ipaddress.ip_address(i)) for i in used_ips} | set(aws_reserved(cidr))
    for p in used_prefixes:
        used.update(str(a) for a in ipaddress.ip_network(p, strict=False))
    return net.num_addresses - len(used)


@collector("aws_subnets", ("aws",), ("subnet.free_ips", "subnet.free_aligned_28"))
def aws_subnets(ctx: Ctx):
    """Free IPs and free aligned /28 blocks per subnet tagged Project=<project> (describe-subnets, -network-interfaces)."""
    rows = ctx.aws("ec2", "describe-subnets", "--filters", f"Name=tag:Project,Values={ctx.targets['project_tag']}",
                   "--query", "Subnets[].{n:Tags[?Key=='Name']|[0].Value,f:AvailableIpAddressCount,"
                              "c:CidrBlock,i:SubnetId}") or []
    if not rows:
        raise Unavailable(f"no subnets tagged Project={ctx.targets['project_tag']} (not deployed)")
    out = [ctx.sample("subnet.free_ips", r["n"] or "unnamed-subnet", r["f"], "count") for r in rows]
    pats = ctx.targets.get("aligned28_subnets", ["*"])
    want = [r for r in rows if r.get("i") and r.get("c")
            and any(fnmatch.fnmatchcase(r["n"] or "", p) for p in pats)]
    if not want:
        return out
    try:
        enis = ctx.aws("ec2", "describe-network-interfaces",
                       "--filters", "Name=subnet-id,Values=" + ",".join(r["i"] for r in want),
                       "--query", "NetworkInterfaces[].{s:SubnetId,ips:PrivateIpAddresses[].PrivateIpAddress,"
                                  "p:Ipv4Prefixes[].Ipv4Prefix}") or []
    except Unavailable as e:
        ctx.notes.append(f"free aligned /28s: {e}")
        return out
    out += aligned28_samples(ctx, want, enis)
    return out


def aligned28_samples(ctx: Ctx, subnets: list[dict], enis: list[dict]) -> list[Sample]:
    """subnets: [{n, c, i, f}] from describe-subnets; enis: [{s, ips, p}] (pure, unit-testable)."""
    ips: dict[str, list] = defaultdict(list)
    prefixes: dict[str, list] = defaultdict(list)
    for e in enis:
        ips[e.get("s")] += e.get("ips") or []
        prefixes[e.get("s")] += e.get("p") or []
    out = []
    for r in subnets:
        free = free_aligned_blocks(r["c"], ips[r["i"]], prefixes[r["i"]])
        total = ipaddress.ip_network(r["c"], strict=False).num_addresses // 16
        out.append(ctx.sample("subnet.free_aligned_28", r["n"] or "unnamed-subnet", free, "blocks",
                              f"{free} of {total} aligned /28s free; {r.get('f', '?')} free IPs"))
    return out


# ====================================================================== AWS VPN

def _vpn_tunnels(ctx: Ctx) -> list[dict]:
    """[{conn, component, outside_ip, status, routes}] -- outside IPs stay in memory only."""
    names = ",".join(ctx.targets["vpn_connections"])
    rows = ctx.aws("ec2", "describe-vpn-connections",
                   "--filters", f"Name=tag:Name,Values={names}", "Name=state,Values=available",
                   "--query", "VpnConnections[].{n:Tags[?Key=='Name']|[0].Value,"
                              "t:VgwTelemetry[].{ip:OutsideIpAddress,s:Status,r:AcceptedRouteCount},"
                              "o:Options.TunnelOptions[].{ip:OutsideIpAddress,c:TunnelInsideCidr}}") or []
    if not rows:
        raise Unavailable("no available VPN connections named " + names + " (not deployed)")
    cidrs = ctx.targets["tunnel_inside_cidrs"]
    out = []
    for r in rows:
        by_ip = {o["ip"]: o.get("c") for o in (r.get("o") or [])}
        for i, t in enumerate(r.get("t") or [], 1):
            comp = cidrs.get(by_ip.get(t["ip"]), f"{r['n']}-tunnel{i}")
            out.append({"conn": r["n"], "component": comp, "ip": t["ip"], "status": t["s"], "routes": t["r"]})
    return out


@collector("aws_vpn", ("aws",), ("vpn.tunnel_up", "vpn.accepted_routes"))
def aws_vpn(ctx: Ctx):
    """Per-tunnel state and BGP accepted routes (describe-vpn-connections, narrow --query, no PSKs)."""
    out = []
    for t in _vpn_tunnels(ctx):
        out.append(ctx.sample("vpn.tunnel_up", t["component"], 1 if t["status"] == "UP" else 0, "state", t["status"]))
        out.append(ctx.sample("vpn.accepted_routes", t["component"], t["routes"] or 0, "count"))
    return out


@collector("aws_vpn_cloudwatch", ("aws",), ("vpn.cw_tunnel_state", "vpn.cw_data_in", "vpn.cw_data_out"))
def aws_vpn_cloudwatch(ctx: Ctx):
    """CloudWatch TunnelState (Minimum), TunnelDataIn/Out (Sum), 5-min periods, one GetMetricData call."""
    tunnels = _vpn_tunnels(ctx)
    queries, keys = [], {}
    for i, t in enumerate(tunnels):
        for metric, stat, sig, unit in (("TunnelState", "Minimum", "vpn.cw_tunnel_state", "state"),
                                        ("TunnelDataIn", "Sum", "vpn.cw_data_in", "bytes"),
                                        ("TunnelDataOut", "Sum", "vpn.cw_data_out", "bytes")):
            qid = f"m{i}{metric.lower()}"
            keys[qid] = (sig, t["component"], unit)
            queries.append({"Id": qid, "MetricStat": {"Metric": {
                "Namespace": "AWS/VPN", "MetricName": metric,
                "Dimensions": [{"Name": "TunnelIpAddress", "Value": t["ip"]}]}, "Period": 300, "Stat": stat}})
    end = datetime.fromtimestamp(ctx.now, timezone.utc)
    start = datetime.fromtimestamp(ctx.now - 1800, timezone.utc)
    res = ctx.aws("cloudwatch", "get-metric-data", "--metric-data-queries", json.dumps(queries),
                  "--start-time", start.strftime("%Y-%m-%dT%H:%M:%SZ"), "--end-time", end.strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "--query", "MetricDataResults[].{i:Id,t:Timestamps,v:Values}") or []
    out = []
    for r in res:
        sig, comp, unit = keys[r["i"]]
        for ts, v in zip(r.get("t") or [], r.get("v") or []):
            out.append(ctx.sample(sig, comp, v, unit, ts=_parse_ts(ts)))
    if not out:
        ctx.notes.append("CloudWatch returned no datapoints yet (published every 5 min)")
    return out


# ====================================================================== Azure VPN gateway

@collector("azure_vpngw", ("az",), ("azure.bgp_peer_up", "azure.bgp_routes_received", "azure.learned_routes"))
def azure_vpngw(ctx: Ctx):
    """BGP peer status and learned-route counts on the Azure VPN gateway."""
    rg, gw = ctx.targets["azure_rg"], ctx.targets["azure_vpngw"]
    peers_map = ctx.targets["azure_bgp_peers"]
    peers = ctx.az("network", "vnet-gateway", "list-bgp-peer-status", "-g", rg, "-n", gw,
                   "--query", "value[].{p:neighbor,s:state,r:routesReceived}") or []
    state: dict[str, list] = {}
    for p in peers:
        comp = peers_map.get(p["p"])
        if not comp:
            continue
        up, routes = state.get(comp, [0, 0])
        state[comp] = [max(up, 1 if p["s"] == "Connected" else 0), max(routes, int(p.get("r") or 0))]
    out = []
    for comp, (up, routes) in sorted(state.items()):
        out.append(ctx.sample("azure.bgp_peer_up", comp, up, "state"))
        out.append(ctx.sample("azure.bgp_routes_received", comp, routes, "count"))
    try:
        learned = ctx.az("network", "vnet-gateway", "list-learned-routes", "-g", rg, "-n", gw,
                         "--query", "value[?origin=='EBgp'].sourcePeer") or []
        counts = {comp: 0 for comp in peers_map.values()}
        for src in learned:
            if src in peers_map:
                counts[peers_map[src]] += 1
        out += [ctx.sample("azure.learned_routes", c, n, "count") for c, n in sorted(counts.items())]
    except Unavailable as e:
        ctx.notes.append(f"learned routes: {e}")
    return out


# ====================================================================== firewalls

# Counter snapshot: CPU jiffies (/proc/stat), rx/tx packets summed over every interface except
# lo (/proc/net/dev), and a timestamp. Two snapshots bracket the work in the middle (a sleep on
# the AWS firewalls, the ping rounds on the Azure firewall), so CPU % and packets/s are averages
# over that interval, computed without keeping any state on the VM or between runs.
SNAP_FN = r"""
snap() {
  echo "cpu_$1=$(head -n1 /proc/stat)"
  echo "net_$1=$(awk 'NR>2 { sub(/^ */, ""); split($0, a, ":"); if (a[1] == "lo") next; split(a[2], f, " "); rx += f[2]; tx += f[10] } END { print rx+0, tx+0 }' /proc/net/dev)"
  echo "t_$1=$(date +%s.%N)"
}
snap a
"""

FW_SCRIPT = r"""
snap b
echo "loadavg=$(cut -d' ' -f1-3 /proc/loadavg)"
c=$(conntrack -C 2>/dev/null || cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
echo "conntrack_count=${c:-}"
echo "conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)"
conntrack -L -n 2>/dev/null | awk '{d="";p=""; for(i=1;i<=NF;i++){ if($i ~ /^dst=/ && d=="") d=substr($i,5); if($i ~ /^dport=/ && p=="") p=substr($i,7) } n[d":"p]++; t++ }
  END { m=0; for (k in n) if (n[k] > m) m = n[k]; print "snat_entries=" t+0; print "snat_top_dest=" m+0 }'
nft list chain inet fw forward 2>/dev/null | awk '/fw-invalid/ { for(i=1;i<=NF;i++) if($i=="packets") print "nft_invalid=" $(i+1) }
  /fw-drop/ { for(i=1;i<=NF;i++) if($i=="packets") print "nft_drop=" $(i+1) }'
"""

# Fine loss probe (Azure firewall): __ROUNDS__ back-to-back rounds; in each round every
# destination gets `ping -c __COUNT__ -i __INTERVAL__ -q` in parallel (200 x 0.2 s = 40 s,
# 0.5 % resolution). Each result line carries the round's start time.
PING_SCRIPT = r"""
r=0
while [ "$r" -lt __ROUNDS__ ]; do
  r=$((r + 1))
  ts=$(date +%s)
  for d in __TARGETS__; do
    (
      o=$(ping -c __COUNT__ -i __INTERVAL__ -W 1 -q "$d" 2>&1)
      l=$(printf '%s\n' "$o" | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p')
      rt=$(printf '%s\n' "$o" | sed -n 's#^rtt [^=]*= [0-9.]*/\([0-9.]*\)/.*#\1#p')
      echo "ping $d ts=$ts loss=${l:-} rtt=${rt:-}"
    ) &
  done
  wait
done
"""


def fw_script(work: str) -> str:
    """snapshot a, the work (sleep or pings), snapshot b, then the counters."""
    return SNAP_FN + work + FW_SCRIPT


def ping_script(targets: dict, ips: list[str]) -> str:
    """The probe script for already-resolved destination IPs (see resolve_probe_targets)."""
    return (PING_SCRIPT.replace("__TARGETS__", " ".join(ips))
            .replace("__COUNT__", str(int(targets.get("ping_count", 200))))
            .replace("__INTERVAL__", f"{float(targets.get('ping_interval_s', 0.2)):g}")
            .replace("__ROUNDS__", str(int(targets.get("ping_rounds", 1)))))


def _cpu(line: str | None):
    """'cpu  user nice system idle iowait irq softirq steal ...' -> (total, idle, steal)."""
    if not line:
        return None
    parts = line.split()
    if not parts or parts[0] != "cpu":
        return None
    try:
        v = [float(x) for x in parts[1:9]]
    except ValueError:
        return None
    v += [0.0] * (8 - len(v))
    return sum(v), v[3] + v[4], v[7]


def _rates(kv: dict) -> dict:
    """CPU busy %, steal % and packets/s between snapshot a and b (empty if not available)."""
    out = {}
    try:
        dt = float(kv["t_b"]) - float(kv["t_a"])
    except (KeyError, ValueError):
        return out
    if dt <= 0:
        return out
    a, b = _cpu(kv.get("cpu_a")), _cpu(kv.get("cpu_b"))
    if a and b and b[0] > a[0]:
        dtot = b[0] - a[0]
        out["cpu_pct"] = round(100 * (dtot - (b[1] - a[1])) / dtot, 2)
        out["cpu_steal_pct"] = round(100 * (b[2] - a[2]) / dtot, 2)
    try:
        rxa, txa = (float(x) for x in kv["net_a"].split())
        rxb, txb = (float(x) for x in kv["net_b"].split())
        d = (rxb + txb) - (rxa + txa)
        if d >= 0:                         # a counter reset gives no sample rather than a bad one
            out["pps"] = round(d / dt, 1)
    except (KeyError, ValueError):
        pass
    out["interval_s"] = round(dt, 1)
    return out


def parse_fw_output(text: str, component: str, ctx: Ctx, nat_range: int,
                    names: dict[str, str] | None = None) -> list[Sample]:
    """names: destination IP -> probe target name. A path is recorded as `<fw>-><name>`, with
    the IP in the detail; without a name it is `<fw>-><ip>` (the Session 1 recordings)."""
    kv, pings = {}, []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("ping "):
            parts = line.split()
            d = parts[1]
            vals = dict(p.split("=", 1) for p in parts[2:] if "=" in p)
            pings.append((d, vals.get("loss"), vals.get("rtt"), vals.get("ts")))
        elif "=" in line:
            k, v = line.split("=", 1)
            kv[k.strip()] = v.strip()

    def num(k):
        try:
            return float(kv[k])
        except (KeyError, ValueError):
            return None

    out = []
    # conntrack_count = entries in use (conntrack -C / nf_conntrack_count); conntrack_max = the
    # table size (nf_conntrack_max). Session 1's 7,168 on the Azure firewall was a count.
    c, m = num("conntrack_count"), num("conntrack_max")
    if c is not None:
        out.append(ctx.sample("fw.conntrack_count", component, c, "count", "entries in use"))
    if m:
        out.append(ctx.sample("fw.conntrack_max", component, m, "count", "nf_conntrack_max"))
        if c is not None:
            if c > m:
                ctx.notes.append(f"{component}: conntrack count {c:g} > max {m:g}; check the labels")
            else:
                out.append(ctx.sample("fw.conntrack_pct", component, round(100 * c / m, 3), "pct"))
    if num("snat_entries") is not None:
        out.append(ctx.sample("fw.snat_entries", component, num("snat_entries"), "count"))
        out.append(ctx.sample("fw.nat_ports_pct", component, round(100 * num("snat_top_dest") / nat_range, 3), "pct"))
    for key, sig in (("nft_drop", "fw.nft_drop_total"), ("nft_invalid", "fw.nft_invalid_total")):
        if num(key) is not None:
            out.append(ctx.sample(sig, component, num(key), "packets"))
    rates = _rates(kv)
    span = f"over {rates['interval_s']:g} s" if "interval_s" in rates else ""
    if "cpu_pct" in rates:
        out.append(ctx.sample("fw.cpu_pct", component, rates["cpu_pct"], "pct", span))
        out.append(ctx.sample("fw.cpu_steal_pct", component, rates["cpu_steal_pct"], "pct", span))
    if "pps" in rates:
        out.append(ctx.sample("fw.pps", component, rates["pps"], "pps", span))
        lim = (ctx.targets.get("fw_pps_limit") or {}).get(component)
        if lim:
            out.append(ctx.sample("fw.pps_limit", component, float(lim), "pps", "estimate"))
    la = kv.get("loadavg", "").split()
    if la:
        try:
            out.append(ctx.sample("fw.load1", component, float(la[0]), "load"))
        except ValueError:
            pass
    names = names or {}
    for d, loss, rtt, ts in pings:
        comp = f"{component}->{names.get(d, d)}"
        det = d if d in names else ""
        t = float(ts) if ts not in (None, "") else None
        if loss not in (None, ""):
            out.append(ctx.sample("path.loss_pct", comp, float(loss), "pct", det, ts=t))
        if rtt not in (None, ""):
            out.append(ctx.sample("path.rtt_ms", comp, float(rtt), "ms", det, ts=t))
    return out


@collector("aws_firewalls", ("aws",), ("fw.conntrack_pct", "fw.nat_ports_pct", "fw.nft_drop_total", "fw.nft_invalid_total",
                                       "fw.cpu_pct", "fw.pps"))
def aws_firewalls(ctx: Ctx):
    """Conntrack, SNAT, nftables, CPU and packet-rate counters on fw-a / fw-b via SSM send-command (read-only)."""
    fws = ctx.targets["aws_firewalls"]
    rows = ctx.aws("ec2", "describe-instances", "--filters", f"Name=tag:Name,Values={','.join(fws)}",
                   "Name=instance-state-name,Values=running",
                   "--query", "Reservations[].Instances[].{i:InstanceId,n:Tags[?Key=='Name']|[0].Value}") or []
    if not rows:
        raise Unavailable("no running " + "/".join(fws) + " instances (not deployed)")
    script = fw_script(f"sleep {int(ctx.targets.get('fw_sample_s', 10))}\n")
    params = json.dumps({"commands": [script], "executionTimeout": ["60"]})
    sent = []
    for r in rows:
        cid = ctx.aws("ssm", "send-command", "--instance-ids", r["i"], "--document-name", "AWS-RunShellScript",
                      "--comment", "mindbridge read-only telemetry", "--parameters", params,
                      "--query", "Command.CommandId")
        sent.append((r, cid))
    out = []
    for r, cid in sent:
        comp = fws.get(r["n"], r["n"])
        text, status = "", "Pending"
        while ctx.remaining() > 3:
            time.sleep(2)
            try:
                inv = ctx.aws("ssm", "get-command-invocation", "--instance-id", r["i"], "--command-id", cid,
                              "--query", "{s:Status,o:StandardOutputContent}")
            except Unavailable:
                continue  # InvocationDoesNotExist for the first second or two
            status, text = inv["s"], inv.get("o") or ""
            if status not in ("Pending", "InProgress", "Delayed"):
                break
        if status != "Success":
            ctx.notes.append(f"{comp}: ssm {status}")
            continue
        out += parse_fw_output(text, comp, ctx, int(ctx.targets["nat_port_range"]))
    return out


# ---------------------------------------------------------------- path-probe targets
#
# The probe destinations follow the topology. Session 2 raised a false 100 % loss alarm because
# the probe still pinged the Session 1 test host 10.10.0.10, which does not exist when
# enable_test_hosts = false. Each target in signals.targets.path_probe_targets is looked up
# first; a target that can't be resolved or found is skipped and recorded as
# "unavailable: target absent", so it produces no loss samples at all.
#
#   resolve: aws_instance   a running EC2 instance with this Name tag (tag:), its private IP
#   resolve: eks_pod        a Running pod (context, namespace, selector) whose IP is in one of
#                           `cidrs` (e.g. the AZ's node and pod subnets)
#   resolve: k8s_service    a LoadBalancer Service's ingress IP (an internal LB / ILB)
#   resolve: static         `ip` as given, never checked (avoid: it is how the false alarm happened)

class TargetAbsent(Exception):
    pass


def _resolve_aws_instance(ctx: Ctx, t: dict) -> str:
    if not shutil.which("aws"):
        raise TargetAbsent("aws CLI not installed")
    try:
        rows = ctx.aws("ec2", "describe-instances", "--filters", f"Name=tag:Name,Values={t['tag']}",
                       "Name=instance-state-name,Values=running",
                       "--query", "Reservations[].Instances[].PrivateIpAddress", timeout=20) or []
    except Unavailable as e:
        raise TargetAbsent(str(e))
    rows = [r for r in rows if r]
    if not rows:
        raise TargetAbsent(f"no running instance tagged Name={t['tag']}")
    if t.get("ip") and t["ip"] not in rows:
        raise TargetAbsent(f"instance {t['tag']} does not have {t['ip']}")
    return t.get("ip") or rows[0]


def _in_cidrs(ip: str, cidrs) -> bool:
    if not cidrs:
        return True
    a = ipaddress.ip_address(ip)
    return any(a in ipaddress.ip_network(c, strict=False) for c in cidrs)


def pick_pod_ip(pods: dict, cidrs=None) -> str | None:
    """First Running, Ready pod whose IP is in `cidrs` (pure, unit-testable)."""
    for p in sorted(pods.get("items", []), key=lambda p: (p.get("metadata") or {}).get("name", "")):
        st = p.get("status") or {}
        ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in st.get("conditions") or [])
        ip = st.get("podIP")
        if st.get("phase") == "Running" and ready and ip and _in_cidrs(ip, cidrs):
            return ip
    return None


def _resolve_eks_pod(ctx: Ctx, t: dict) -> str:
    if not shutil.which("kubectl"):
        raise TargetAbsent("kubectl not installed")
    try:
        pods = ctx.run(["kubectl", "--context", t["context"], "--request-timeout=10s", "get", "pods",
                        "-n", t["namespace"], "-l", t["selector"], "-o", "json"], timeout=20) or {}
    except Unavailable as e:
        raise TargetAbsent(str(e))
    ip = pick_pod_ip(pods, t.get("cidrs"))
    if not ip:
        raise TargetAbsent(f"no Running pod {t['selector']} in {t['context']}/{t['namespace']}"
                           + (f" with an IP in {', '.join(t['cidrs'])}" if t.get("cidrs") else ""))
    return ip


def _resolve_k8s_service(ctx: Ctx, t: dict) -> str:
    if not shutil.which("kubectl"):
        raise TargetAbsent("kubectl not installed")
    try:
        svc = ctx.run(["kubectl", "--context", t["context"], "--request-timeout=10s", "get", "service",
                       "-n", t["namespace"], t["service"], "-o", "json"], timeout=20) or {}
    except Unavailable as e:
        raise TargetAbsent(str(e))
    ing = (((svc.get("status") or {}).get("loadBalancer") or {}).get("ingress") or [])
    ip = next((i.get("ip") for i in ing if i.get("ip")), None)
    if not ip:
        raise TargetAbsent(f"service {t['namespace']}/{t['service']} has no load balancer IP")
    return ip


RESOLVERS = {"aws_instance": _resolve_aws_instance, "eks_pod": _resolve_eks_pod,
             "k8s_service": _resolve_k8s_service, "static": lambda ctx, t: t["ip"]}


def resolve_probe_targets(ctx: Ctx) -> dict[str, str]:
    """-> {ip: target name} for the targets that exist now. Absent ones go into ctx.notes."""
    out: dict[str, str] = {}
    for t in ctx.targets.get("path_probe_targets") or []:
        try:
            ip = RESOLVERS[t.get("resolve", "static")](ctx, t)
            ipaddress.ip_address(ip)
        except (TargetAbsent, ValueError) as e:
            ctx.notes.append(f"probe {t['name']}: unavailable: target absent ({scrub(str(e))[:120]})")
            continue
        if ip in out:
            ctx.notes.append(f"probe {t['name']}: same IP as {out[ip]}, skipped")
            continue
        out[ip] = t["name"]
    return out


@collector("azure_firewall", ("az",), ("fw.conntrack_pct", "fw.nat_ports_pct", "fw.cpu_pct", "fw.pps",
                                     "path.loss_pct", "path.rtt_ms"))
def azure_firewall(ctx: Ctx):
    """Counters plus a fine loss probe (200 pings per present target per round) via one az vm run-command."""
    rg, vm = ctx.targets["azure_rg"], ctx.targets["azure_fw_vm"]
    ctx.az("vm", "show", "-g", rg, "-n", vm, "--query", "name")   # Unavailable if not deployed
    names = resolve_probe_targets(ctx)
    # One invocation does everything: Run Command holds one lock per VM, so a separate probe
    # would queue behind (or block) the counters. With no target present, the snapshots
    # bracket a plain sleep instead.
    work = ping_script(ctx.targets, list(names)) if names else f"sleep {int(ctx.targets.get('fw_sample_s', 10))}\n"
    script = fw_script(work)
    msg = ctx.run(["az", "vm", "run-command", "invoke", "-g", rg, "-n", vm, "--command-id", "RunShellScript",
                   "--scripts", script, "--query", "value[0].message", "-o", "tsv", "--only-show-errors"],
                  parse_json=False)
    stdout = msg.split("[stdout]", 1)[-1].split("[stderr]", 1)[0]
    out = parse_fw_output(stdout, "az-fw", ctx, int(ctx.targets["nat_port_range"]), names)
    # Only targets that were resolved this run may produce path samples
    return [s for s in out if not s.signal.startswith("path.")
            or s.component.split("->", 1)[-1] in names.values()]


# ====================================================================== Kubernetes

IP_ERROR = re.compile(r"assign an ip|failed to assign|no available ip|insufficientfreeaddresses|ipamd|"
                      r"no ip addresses|ip address space|subnet .* is full|assignprivateipaddresses", re.I)
# Reasons emitted by AWS Node Termination Handler and Karpenter. Plain EKS managed node groups
# emit none of these: see the README ("What EKS managed node groups emit").
SPOT_REASONS = {"SpotInterruption", "SpotInterrupted", "RebalanceRecommendation", "SpotRebalanceRecommendation",
                "InstanceRebalanceRecommendation", "ScheduledEvent", "TerminatingOnInterruption"}
PRESSURE = {"MemoryPressure", "DiskPressure", "PIDPressure", "NetworkUnavailable"}
EVENT_WINDOW_S = 600
# aws/eks labels every node with its VPC CNI pod-IP mode (local.pod_ip_mode in terraform/aws/eks).
POD_IP_MODE_LABEL = "cloudbridge.io/pod-ip-mode"
POD_IP_MODES = ("secondary-ip", "prefix", "secondary-ip-custom-net", "prefix-custom-net")


def _parse_ts(v) -> float:
    if v is None:
        return 0.0
    if isinstance(v, (int, float)):
        return float(v)
    s = str(v).replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(s).timestamp()
    except ValueError:
        return 0.0


def _event_ts(e: dict) -> float:
    return max(_parse_ts(e.get("lastTimestamp")), _parse_ts(e.get("eventTime")),
               _parse_ts((e.get("series") or {}).get("lastObservedTime")), _parse_ts(e.get("firstTimestamp")))


def k8s_samples(ctx: Ctx, cluster: str, pods: dict, nodes: dict, events: dict) -> list[Sample]:
    """Pure parser over kubectl -o json output (unit-testable)."""
    out = []
    reasons: dict[str, int] = {}
    for p in pods.get("items", []):
        r = None
        for c in (p.get("status") or {}).get("conditions") or []:
            if c.get("type") == "PodScheduled" and c.get("status") != "True":
                r = c.get("reason") or "Unscheduled"
        if not r:
            for cs in (p.get("status") or {}).get("containerStatuses") or []:
                r = ((cs.get("state") or {}).get("waiting") or {}).get("reason") or r
        r = r or "Pending"
        reasons[r] = reasons.get(r, 0) + 1
    detail = ", ".join(f"{k} x{v}" for k, v in sorted(reasons.items()))
    out.append(ctx.sample("k8s.pending_pods", cluster, sum(reasons.values()), "pods", detail))

    for n in nodes.get("items", []):
        labels = (n.get("metadata") or {}).get("labels") or {}
        zone = labels.get("topology.kubernetes.io/zone", "nozone")
        bad = []
        for c in (n.get("status") or {}).get("conditions") or []:
            if c.get("type") == "Ready" and c.get("status") != "True":
                bad.append("NotReady")
            elif c.get("type") in PRESSURE and c.get("status") == "True":
                bad.append(c["type"])
        if (n.get("spec") or {}).get("unschedulable"):
            bad.append("Cordoned")
        out.append(ctx.sample("k8s.node_bad_conditions", f"{cluster}:{zone}", len(bad), "conditions", ",".join(bad)))

    # Nodes per pod-IP mode, one sample per mode (0 included, so a mode that is gone reads 0).
    # During a node roll both the old and the new mode are > 0. Clusters without the label
    # (AKS) emit nothing.
    modes: dict[str, int] = {}
    for n in nodes.get("items", []):
        m = ((n.get("metadata") or {}).get("labels") or {}).get(POD_IP_MODE_LABEL)
        if m:
            modes[m] = modes.get(m, 0) + 1
    if modes:
        for m in sorted(set(POD_IP_MODES) | set(modes)):
            out.append(ctx.sample("k8s.pod_ip_mode", f"{cluster}:{m}", modes.get(m, 0), "nodes", POD_IP_MODE_LABEL))

    since = ctx.now - EVENT_WINDOW_S
    sandbox = ip_err = spot = 0
    spot_reasons: dict[str, int] = {}
    for e in events.get("items", []):
        if _event_ts(e) < since:
            continue
        reason, msg = e.get("reason") or "", e.get("message") or ""
        if reason == "FailedCreatePodSandBox":
            sandbox += 1
            if IP_ERROR.search(msg):
                ip_err += 1
        elif reason in ("FailedScheduling",) and IP_ERROR.search(msg):
            ip_err += 1
        if reason in SPOT_REASONS:
            spot += 1
            spot_reasons[reason] = spot_reasons.get(reason, 0) + 1
    out.append(ctx.sample("k8s.sandbox_failures", cluster, sandbox, "events"))
    out.append(ctx.sample("k8s.ip_assign_errors", cluster, ip_err, "events"))
    out.append(ctx.sample("k8s.spot_events", cluster, spot, "events",
                          ", ".join(f"{k} x{v}" for k, v in sorted(spot_reasons.items()))))
    return out


@collector("kubernetes", ("kubectl",), ("k8s.pending_pods", "k8s.node_bad_conditions", "k8s.ip_assign_errors",
                                        "k8s.sandbox_failures", "k8s.spot_events", "k8s.pod_ip_mode"))
def kubernetes(ctx: Ctx):
    """Pending pods, node conditions, pod-IP mode and warning events per kube context (kubectl get, read-only)."""
    have = set(ctx.run(["kubectl", "config", "get-contexts", "-o", "name"], parse_json=False).split())
    out = []
    for cluster in ctx.targets["k8s_contexts"]:
        if cluster not in have:
            ctx.notes.append(f"{cluster}: no kube context")
            continue
        base = ["kubectl", "--context", cluster, "--request-timeout=10s"]
        try:
            pods = ctx.run(base + ["get", "pods", "-A", "--field-selector=status.phase=Pending", "-o", "json"], timeout=20)
            nodes = ctx.run(base + ["get", "nodes", "-o", "json"], timeout=20)
            events = ctx.run(base + ["get", "events", "-A", "--field-selector=type=Warning", "-o", "json"], timeout=20)
        except Unavailable as e:
            ctx.notes.append(f"{cluster}: {e}")
            continue
        out += k8s_samples(ctx, cluster, pods or {}, nodes or {}, events or {})
    return out


@collector("aws_spot", ("aws",), ("aws.spot_rebalance",))
def aws_spot(ctx: Ctx):
    """Spot rebalance / interruption replacements in the EKS node group ASGs (describe-scaling-activities)."""
    name = ctx.targets["eks_cluster_name"]
    asgs = ctx.aws("autoscaling", "describe-auto-scaling-groups",
                   "--filters", f"Name=tag:eks:cluster-name,Values={name}",
                   "--query", "AutoScalingGroups[].{n:AutoScalingGroupName,g:Tags[?Key=='eks:nodegroup-name']|[0].Value}") or []
    if not asgs:
        raise Unavailable(f"no Auto Scaling groups tagged eks:cluster-name={name} (not deployed)")
    rx = re.compile(r"rebalanc|interrupt", re.I)
    out = []
    for a in asgs:
        acts = ctx.aws("autoscaling", "describe-scaling-activities", "--auto-scaling-group-name", a["n"],
                       "--max-items", "20", "--query", "Activities[].{t:StartTime,c:Cause,d:Description}") or []
        recent = [x for x in acts if _parse_ts(x.get("t")) >= ctx.now - 900
                  and rx.search(f"{x.get('c') or ''} {x.get('d') or ''}")]
        out.append(ctx.sample("aws.spot_rebalance", a.get("g") or name, len(recent), "activities"))
    return out


# ====================================================================== quotas, countdowns

@collector("azure_quotas", ("az",), ("quota.azure_public_ips", "quota.azure_cores", "quota.azure_bs_vcpu",
                                     "quota.azure_basv2_vcpu"))
def azure_quotas(ctx: Ctx):
    """Public IP and vCPU quota usage in the Azure location (network list-usages, vm list-usage)."""
    loc = ctx.targets["azure_location"]
    out = []
    net = ctx.az("network", "list-usages", "--location", loc,
                 "--query", "[?name.value=='PublicIPAddresses'].{c:currentValue,l:limit}") or []
    for r in net:
        out += [ctx.sample("quota.azure_public_ips", loc, float(r["c"]), "count"),
                ctx.sample("quota.azure_public_ips.limit", loc, float(r["l"]), "count")]
    vm = ctx.az("vm", "list-usage", "--location", loc,
                "--query", "[?name.value=='cores' || name.value=='standardBSFamily' || name.value=='standardBasv2Family']"
                           ".{n:name.value,c:currentValue,l:limit}") or []
    names = {"cores": "quota.azure_cores", "standardBSFamily": "quota.azure_bs_vcpu",
             "standardBasv2Family": "quota.azure_basv2_vcpu"}
    for r in vm:
        sig = names[r["n"]]
        out += [ctx.sample(sig, loc, float(r["c"]), "vCPU"), ctx.sample(sig + ".limit", loc, float(r["l"]), "vCPU")]
    return out


@collector("domain", ("aws",), ("domain.expiry_days", "domain.auto_renew"))
def domain(ctx: Ctx):
    """Days until the domain expires, and the auto-renew flag (route53domains get-domain-detail)."""
    d = ctx.targets["domain"]
    r = ctx.aws("route53domains", "get-domain-detail", "--domain-name", d,
                "--query", "{e:ExpirationDate,a:AutoRenew}", region="us-east-1")
    exp = _parse_ts(r.get("e"))
    if not exp:
        raise Unavailable("no expiration date returned")
    return [ctx.sample("domain.expiry_days", d, round((exp - ctx.now) / 86400, 3), "days",
                       datetime.fromtimestamp(exp, timezone.utc).strftime("expires %Y-%m-%d")),
            ctx.sample("domain.auto_renew", d, 1 if r.get("a") else 0, "flag")]


@collector("budgets", (), ("budget.actual_usd", "budget.forecast_usd", "budget.limit_usd"))
def budgets(ctx: Ctx):
    """AWS budget and Azure consumption budget: actual, forecast and limit (USD)."""
    out = []
    if shutil.which("aws"):
        try:
            acct = ctx.run(["aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text",
                            "--no-cli-pager"], parse_json=False)   # used in memory only, never stored
            b = ctx.aws("budgets", "describe-budget", "--account-id", acct, "--budget-name", ctx.targets["aws_budget"],
                        "--query", "Budget.{l:BudgetLimit.Amount,a:CalculatedSpend.ActualSpend.Amount,"
                                   "f:CalculatedSpend.ForecastedSpend.Amount}", region="us-east-1")
            out += _budget_samples(ctx, "aws", b)
        except Unavailable as e:
            ctx.notes.append(f"aws budget: {e}")
    else:
        ctx.notes.append("aws CLI not installed")
    if shutil.which("az"):
        try:
            b = ctx.az("consumption", "budget", "show", "--budget-name", ctx.targets["azure_budget"],
                       "--query", "{l:amount,a:currentSpend.amount,f:forecastSpend.amount}")
            out += _budget_samples(ctx, "azure", b)
        except Unavailable as e:
            ctx.notes.append(f"azure budget: {e}")
    else:
        ctx.notes.append("az CLI not installed")
    return out


def _budget_samples(ctx: Ctx, comp: str, b: dict | None) -> list[Sample]:
    out = []
    for key, sig in (("a", "budget.actual_usd"), ("f", "budget.forecast_usd"), ("l", "budget.limit_usd")):
        if b and b.get(key) not in (None, ""):
            out.append(ctx.sample(sig, comp, float(b[key]), "USD"))
    return out
