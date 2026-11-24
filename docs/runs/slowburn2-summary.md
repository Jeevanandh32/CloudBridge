# MindBridge AI live slow-burn rerun (Session 3, 2026-11-23)

The same injected failure as Session 1 (`docs/runs/slowburn-summary.md`), this time with the
redesigned loss probe:
- **Ramp:** `tc netem` loss on the Azure hub firewall toward 10.10.0.0/16, 0 → 8 % in 25 steps
  of 84 s (23:30:27 → 00:05:27 UTC), held, then cleared at 00:10:27.
- **Failure point:** injected loss crosses **5 % at 23:52:51** (the SLO breach).
- **Probe:** Session 1 used 20 pings every 5 min (5 % resolution). Session 3 used 2 × 200 pings
  in parallel every 120 s to 4 targets (0.5 % resolution, one sample per target about every
  40 s): the 2 test hosts and one EKS pod per AZ.

## Result

| Target | First warning (time-to-threshold) | **Lead time** | Predicted crossing vs actual, at first warning |
|---|---|---|---|
| app-host-a | 23:43:39 | **9 min** | +6 min |
| app-host-b | 23:38:58 | **14 min** | +1.5 min |
| eks-pod-a | 23:41:01 | **12 min** | +4 min |
| eks-pod-b | 23:40:21 | **12 min** | +2 min |
| **False alarms** | | **0** | |

RTT baseline-deviation warnings also fired before the crossing (23:47:40 and 23:50:58):
average RTT rose from about 14 ms to about 22 ms. netem was configured for loss only, so the
cause of the extra latency isn't established. It may come from the probe's parallel pings
through the qdisc. Count it as a secondary signal, not a proven one.

| Session | Probe | Predicted? | Lead time | False alarms |
|---|---|---|---|---|
| 1 | 20 pings / 5 min | **no** | none | 0 |
| **3** | **400 pings / 2 min** | **yes, all 4 targets** | **9–14 min** | **0** |

## How it was scored

- **The replay CSV:** the stored samples were exported and the 5 % crossing marked as the
  failure (`slowburn2-loss-ramp-only.csv`). Then `python -m mindbridge replay` was run, which uses
  the same detectors as `watch`.
- **Only samples from 23:25 on count.** The full-session file (`slowburn2-loss-replay.csv`) also
  holds the real 100 % loss during Test 2's VPN cut (23:04–23:19). That event triggered alerts
  on the test hosts, which were correct for Test 2 but would wrongly look like early warnings for
  this ramp.
- **This was a ramp the detectors were designed for.** It tests the probe and the detector, not
  a surprise failure. Abrupt failures (an instance crash, a config mistake) give no warning
  signs. Those are covered by the what-if sweep and the pre-change check, not by predict mode.
