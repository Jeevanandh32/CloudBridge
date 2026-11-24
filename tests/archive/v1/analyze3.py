"""Numbers for Test 3 (node failure).

Usage: python3 analyze3.py probe.csv pods.csv <break_epoch_ms>
"""

import csv
import sys


def rows(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def secs(ms):
    return f"{ms / 1000:.1f} s"


probe, pods, brk = rows(sys.argv[1]), rows(sys.argv[2]), int(sys.argv[3])

after = [r for r in probe if int(r["epoch_ms"]) >= brk]
failed = [r for r in after if r["http_code"] != "200"]
print(f"requests after break      : {len(after)}")
print(f"failed requests           : {len(failed)} ({100 * len(failed) / max(len(after), 1):.1f}%)")
if failed:
    print(f"failures between          : {secs(int(failed[0]['epoch_ms']) - brk)} and {secs(int(failed[-1]['epoch_ms']) - brk)}")
    codes = {}
    for r in failed:
        codes[r["http_code"]] = codes.get(r["http_code"], 0) + 1
    print(f"failure types             : {codes}   (000 = no answer in 2 s, i.e. sent to a dead target)")
    print(f"user-facing recovery      : {secs(int(failed[-1]['epoch_ms']) - brk + 1000)} after break  <- last failed request")

not_ready = next((p for p in pods if p["node_ready"] != "True"), None)
print(f"node marked NotReady      : {secs(int(not_ready['epoch_ms']) - brk) if not_ready else 'never seen'}")

# Pods "lost" = Ready count dropped below 3; "recovered" = back to 3+3 for good
dip = next((p for p in pods if p["frontend_ready"] != "3" or p["backend_ready"] != "3"), None)
print(f"first Ready pod lost      : {secs(int(dip['epoch_ms']) - brk) if dip else 'never'}")
last_bad = max((int(p["epoch_ms"]) for p in pods if p["frontend_ready"] != "3" or p["backend_ready"] != "3"), default=None)
if last_bad:
    print(f"all 6 pods Ready again    : {secs(last_bad - brk + 2000)} after break  <- recovery time")
