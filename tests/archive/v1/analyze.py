"""Turn a probe.sh CSV into the numbers for docs/results.md.

Usage: python3 analyze.py run.csv <break_epoch_ms> [restore_epoch_ms]

  break   = when the failure was injected (printed by the test script)
  restore = when it was undone (optional, for failback numbers)

A request "fails" if it isn't HTTP 200. Failover is complete at the first 200 from the
standby cloud after the break; failback at the first 200 from the primary after restore.
"""

import csv
import sys


def load(path):
    with open(path) as f:
        return [
            {"t": int(r["epoch_ms"]), "ok": r["http_code"] == "200", "cloud": r["cloud"]}
            for r in csv.DictReader(f)
        ]


def secs(ms):
    return f"{ms / 1000:.1f} s"


def main():
    rows = load(sys.argv[1])
    brk = int(sys.argv[2])
    restore = int(sys.argv[3]) if len(sys.argv) > 3 else None

    primary = rows[0]["cloud"]  # whoever answered first is the primary
    after = [r for r in rows if r["t"] >= brk]
    window = [r for r in after if restore is None or r["t"] < restore]

    first_fail = next((r for r in window if not r["ok"]), None)
    first_standby = next((r for r in window if r["ok"] and r["cloud"] != primary), None)
    failed = sum(not r["ok"] for r in window)

    print(f"primary cloud          : {primary}")
    print(f"requests after break   : {len(window)}")
    print(f"failed requests        : {failed} ({100 * failed / max(len(window), 1):.1f}%)")
    if first_fail:
        print(f"first failure          : {secs(first_fail['t'] - brk)} after break")
    if first_standby:
        print(f"served by standby      : {secs(first_standby['t'] - brk)} after break  <- failover time")
        user_down = [r for r in window if not r["ok"] and r["t"] < first_standby["t"]]
        if user_down:
            print(f"user-visible outage    : {secs(user_down[-1]['t'] - user_down[0]['t'] + 1000)}")
    else:
        print("served by standby      : never (no failover observed)")

    if restore:
        back = next((r for r in rows if r["t"] >= restore and r["ok"] and r["cloud"] == primary), None)
        fails = sum(not r["ok"] for r in rows if r["t"] >= restore)
        print(f"failback to {primary:<10} : {secs(back['t'] - restore) if back else 'not yet'} after restore")
        print(f"failed during failback : {fails}")


if __name__ == "__main__":
    main()
