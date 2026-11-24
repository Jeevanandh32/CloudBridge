"""Regenerates the synthetic slow-burn series (seeded, so the CSVs are reproducible).

    python mindbridge/tests/fixtures/series/make_series.py      # from tools/

Each CSV is ts,signal,component,value,unit,event,note. A row with event=failure marks the
moment the failure becomes user-visible; replay measures lead time against it. Sampling
intervals match the collectors: 1 min for subnets / AWS VPN, 2 min for the Azure gateway,
5 min for firewall Run Command / SSM, ~8 h for budget updates.
"""
from __future__ import annotations

import csv
import math
import random
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
T0 = datetime(2026, 11, 24, 14, 0, tzinfo=timezone.utc)


def ts(minutes: float) -> str:
    return (T0 + timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")


def write(name: str, rows: list[tuple], header_note: str) -> None:
    rows.sort(key=lambda r: (r[0], r[1], r[2]))
    with open(HERE / name, "w", newline="") as fh:
        fh.write(f"# {header_note}\n")
        w = csv.writer(fh)
        w.writerow(["ts", "signal", "component", "value", "unit", "event", "note"])
        for r in rows:
            w.writerow([ts(r[0]), *r[1:]] + [""] * (7 - len(r)))


def binom(rng, n, p):
    return sum(rng.random() < p for _ in range(n))


def pod_ip_drain():
    rng = random.Random(1)
    rows, free, fail = [], 230, None
    for m in range(0, 200):
        if 30 <= m and free > 0:
            # VPC CNI allocates warm IPs in ENI-sized chunks; scale-up adds ~2.5 IPs/min on average
            if rng.random() < 0.5:
                free -= 5
            if rng.random() < 0.1:
                free += 2       # a few pods finish and their IPs come back
            free = max(free, 0)
        rows.append((m, "subnet.free_ips", "cloudbridge-app-pod-a", free, "count"))
        rows.append((m, "subnet.free_ips", "cloudbridge-app-pod-b", 4000 + rng.choice([-2, -1, 0, 0, 0, 1, 2]), "count"))
        if free == 0 and fail is None:
            fail = m
            rows.append((m, "subnet.free_ips", "cloudbridge-app-pod-a", "", "", "failure",
                         "no free IPs: new pods stay in ContainerCreating (FailedCreatePodSandBox)"))
    write("pod-ip-drain.csv", rows, "EKS pod subnet in 2a drains in ENI-sized chunks to 0 free IPs; 2b stays flat.")


def conntrack_ramp():
    rng = random.Random(2)
    rows, fail = [], None
    for i in range(0, 50):
        m = i * 5
        if m < 60:
            pct = 3 + rng.uniform(-1, 1)
        else:
            pct = min(100.0, 3 + (m - 60) * (97 / 150) + rng.uniform(-2, 2))   # leak fills the table in 2.5 h
        rows.append((m, "fw.conntrack_pct", "az-fw", round(pct, 2), "pct"))
        rows.append((m, "fw.conntrack_pct", "fw-a", round(1.5 + rng.uniform(-0.5, 0.5), 2), "pct"))
        if pct >= 100 and fail is None:
            fail = m
            rows.append((m, "fw.conntrack_pct", "az-fw", "", "", "failure",
                         "nf_conntrack: table full, dropping packet"))
    write("conntrack-ramp.csv", rows, "Azure firewall conntrack table filling from a connection leak, polled every 5 min.")


def tunnel_loss():
    rng = random.Random(3)
    rows, fail = [], None
    for i in range(0, 80):
        m = i * 5
        if m < 90:
            p = 0.002
        elif m < 210:
            p = 0.08 * (m - 90) / 120          # creep 0 -> 8 % over 2 h
        elif m < 270:
            p = 0.08
        elif m < 330:
            p = 0.08 * (330 - m) / 60
        else:
            p = 0.002
        lost = binom(rng, 20, p)
        rtt = 31 + rng.gauss(0, 0.8) + 150 * p   # queueing on the degraded path
        rows.append((m, "path.loss_pct", "az-fw->10.10.0.10", lost * 5.0, "pct"))
        rows.append((m, "path.rtt_ms", "az-fw->10.10.0.10", round(rtt, 2), "ms"))
        # the other destination's ICMP flow hashes onto a healthy tunnel
        rows.append((m, "path.loss_pct", "az-fw->10.10.0.74", binom(rng, 20, 0.002) * 5.0, "pct"))
        rows.append((m, "path.rtt_ms", "az-fw->10.10.0.74", round(31.5 + rng.gauss(0, 0.8), 2), "ms"))
        if p >= 0.05 and fail is None and m < 270:
            fail = m
            rows.append((m, "path.loss_pct", "az-fw->10.10.0.10", "", "", "failure",
                         "underlying loss crosses 5 %: TCP throughput collapses, users notice"))
    write("tunnel-loss.csv", rows, "Loss on the tunnel carrying the az-fw -> host-a ping creeps 0 -> 8 % and back; "
                                   "20-packet pings every 5 min, so each sample is a multiple of 5 %.")


def tunnel_loss_fine():
    """The Session 1 slow-burn loss ramp (0 -> 8 % over 35 min, pure loss, RTT flat), sampled the
    way the fine probe sees it: one 200-ping sample per destination per minute (0.5 % steps)."""
    rng = random.Random(5)
    rows = []
    ramp_start, ramp_len, top = 30, 35, 0.08
    fail_m = ramp_start + ramp_len * 0.05 / top          # underlying loss crosses 5 %
    for m in range(0, 76):
        if m < ramp_start:
            p = 0.002
        elif m < ramp_start + ramp_len:
            p = max(0.002, top * (m - ramp_start) / ramp_len)
        else:
            p = top
        rows.append((m, "path.loss_pct", "az-fw->10.10.0.10", binom(rng, 200, p) * 0.5, "pct"))
        rows.append((m, "path.rtt_ms", "az-fw->10.10.0.10", round(19.2 + rng.gauss(0, 0.8), 2), "ms"))
        # the other destination's flow hashes onto a healthy path
        rows.append((m, "path.loss_pct", "az-fw->10.10.0.74", binom(rng, 200, 0.002) * 0.5, "pct"))
        rows.append((m, "path.rtt_ms", "az-fw->10.10.0.74", round(18.6 + rng.gauss(0, 0.8), 2), "ms"))
    rows.append((fail_m, "path.loss_pct", "az-fw->10.10.0.10", "", "", "failure",
                 "underlying loss crosses 5 % (the SLO breach)"))
    write("tunnel-loss-fine.csv", rows, "Session 1's loss ramp (0 -> 8 % over 35 min) as the fine probe would see it: "
                                        "200 pings per destination per minute, 0.5 % resolution. RTT stays flat.")


def healthy_noisy():
    rng = random.Random(4)
    rows = []
    free = 180
    for m in range(0, 360):
        free += rng.choice([-5, 0, 0, 5]) + round((180 - free) * 0.2)
        rows.append((m, "subnet.free_ips", "cloudbridge-app-pod-a", free, "count"))
        up = 0 if m in (200, 201) else 1       # one AWS tunnel maintenance blip: 2 changes
        rows.append((m, "vpn.tunnel_up", "vpn-c0-t1", up, "state"))
        rows.append((m, "vpn.tunnel_up", "vpn-c0-t2", 1, "state"))
        pend = rng.choice([1, 2]) if m % 47 == 0 else 0   # rolling deploys: pending for one sample
        rows.append((m, "k8s.pending_pods", "cloudbridge-eks", pend, "pods"))
    for i in range(0, 180):
        m = i * 2
        rows.append((m, "azure.bgp_peer_up", "vpn-c1-t1", 0 if i == 60 else 1, "state"))
    drops = 0.0
    for i in range(0, 72):
        m = i * 5
        ct = 20 + 5 * math.sin(2 * math.pi * m / 120) + rng.uniform(-2, 2)
        rows.append((m, "fw.conntrack_pct", "az-fw", round(ct, 2), "pct"))
        rows.append((m, "fw.nat_ports_pct", "az-fw", round(0.6 + rng.uniform(-0.2, 0.2), 3), "pct"))
        for comp in ("az-fw->10.10.0.10", "az-fw->10.10.0.74"):
            loss = binom(rng, 20, 0.005) * 5.0
            if comp.endswith(".10") and i == 40:
                loss = 10.0                     # one bad sample
            rows.append((m, "path.loss_pct", comp, loss, "pct"))
            rtt = 31 + rng.gauss(0, 1.5) + (14 if i in (25, 55) else 0)   # two isolated spikes
            rows.append((m, "path.rtt_ms", comp, round(rtt, 2), "ms"))
        drops += max(0.0, rng.gauss(100, 25))   # internet scanners hitting the public IP
        rows.append((m, "fw.nft_drop_total", "az-fw", round(drops), "packets"))
    for d in range(0, 6):
        for h in (2, 10, 18):
            m = (d * 24 + h) * 60
            rows.append((m, "budget.actual_usd", "aws", round(3 + 0.4 * d + 0.05 * h / 8, 2), "USD"))
            rows.append((m, "budget.limit_usd", "aws", 15, "USD"))
    rows.append((0, "domain.expiry_days", "jeevs.click", 328, "days"))
    rows.append((0, "quota.azure_public_ips", "northcentralus", 2, "count"))
    rows.append((0, "quota.azure_public_ips.limit", "northcentralus", 3, "count"))
    write("healthy-noisy.csv", rows, "Healthy but noisy: churn, a tunnel maintenance blip, ping loss blips, RTT spikes, "
                                     "a conntrack sine, scanner drops, slow budget spend. Must raise no alert.")


def bgp_flap():
    rows = []
    # minute -> peer state; flaps start at 30 min, the peer stays down from 51 min
    downs = [(30, 32), (38, 40), (44, 48), (51, 999)]

    def up_at(m):
        return 0 if any(a <= m < b for a, b in downs) else 1
    for m in range(0, 70):
        rows.append((m, "vpn.tunnel_up", "vpn-c1-t2", up_at(m), "state"))
        if m % 2 == 0:
            rows.append((m, "azure.bgp_peer_up", "vpn-c1-t2", up_at(m), "state"))
        rows.append((m, "vpn.tunnel_up", "vpn-c1-t1", 1, "state"))
    rows.append((51, "vpn.tunnel_up", "vpn-c1-t2", "", "", "failure", "tunnel c1-t2 stays down (IKE keeps failing)"))
    write("bgp-flap.csv", rows, "Tunnel c1-t2 flaps three times, then stays down. AWS telemetry every 1 min, Azure BGP "
                                "peer status every 2 min.")


def budget_burn():
    rows, actual, fail = [], 1.0, None
    sessions = {1, 3, 5, 7, 9}
    for d in range(0, 12):
        for k, h in enumerate((2, 10, 18)):
            actual += 0.07 / 3
            if d in sessions:
                actual += 1.0                  # a ~$3 session shows up over three updates
            m = (d * 24 + h) * 60
            day_of_month = 10 + d + h / 24
            forecast = actual / day_of_month * 30
            rows.append((m, "budget.actual_usd", "aws", round(actual, 2), "USD"))
            rows.append((m, "budget.forecast_usd", "aws", round(forecast, 2), "USD"))
            rows.append((m, "budget.limit_usd", "aws", 15, "USD"))
            if actual >= 15 and fail is None:
                fail = m
                rows.append((m, "budget.actual_usd", "aws", "", "", "failure", "AWS budget limit reached"))
    write("budget-burn.csv", rows, "AWS budget: ~$3 per session on days 1, 3, 5, 7, 9 plus fixed costs; AWS updates "
                                   "actual spend about every 8 h.")


if __name__ == "__main__":
    pod_ip_drain()
    conntrack_ramp()
    tunnel_loss()
    tunnel_loss_fine()
    healthy_noisy()
    bgp_flap()
    budget_burn()
    print("wrote", ", ".join(sorted(p.name for p in HERE.glob("*.csv"))))
