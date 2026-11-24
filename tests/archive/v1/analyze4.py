"""Numbers for B1 (BGP down on one tunnel): ping gaps and BGP/IPsec state changes.

Usage: python3 analyze4.py ping.txt state.csv <break_ms> <restore_ms>

ping.txt is `ping -D -O` output: "[1792...123.456] 64 bytes from ..." for replies and
"[1792...] no answer yet for icmp_seq=N" for misses.
"""

import csv
import re
import sys

ping_path, state_path, brk, restore = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

replies, misses = [], []
for line in open(ping_path):
    m = re.match(r"\[(\d+\.\d+)\]", line)
    if not m:
        continue
    t = float(m.group(1)) * 1000
    (replies if "bytes from" in line else misses if "no answer" in line else []).append(t)


def outage(t0, t1):
    """Longest gap between consecutive replies inside [t0, t1), in ms."""
    window = [t for t in replies if t0 - 2000 <= t < t1]
    gaps = [b - a for a, b in zip(window, window[1:])]
    return max(gaps, default=0)


def lost(t0, t1):
    return sum(t0 <= t < t1 for t in misses)


rows = list(csv.DictReader(open(state_path)))
print(f"pings answered          : {len(replies)}, unanswered: {len(misses)}")
print(f"longest gap after break : {outage(brk, restore) / 1000:.1f} s   (lost {lost(brk, restore)} pings)")
print(f"longest gap after restore: {outage(restore, 10**15) / 1000:.1f} s   (lost {lost(restore, 10**15)} pings)")

prev = None
for r in rows:
    state = (r["peers"], r["t1_status"], r["t2_status"])
    if state != prev:
        ref = brk if r["phase"] == "broken" else restore
        print(f"  {r['phase']:<8} +{(int(r['epoch_ms']) - ref) / 1000:6.1f} s  peers: {r['peers']} "
              f"conn t1={r['t1_status']} t2={r['t2_status']}")
        prev = state
