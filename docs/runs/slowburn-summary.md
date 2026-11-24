# MindBridge AI slow-burn tests (Session 1, 2026-11-23)

Goal: inject failures that build up gradually and measure how early MindBridge AI warns
(lead time = failure time − first alert), plus false alarms. Both ramps ran at the same time,
18:34–19:14 UTC, started from the Azure hub firewall.

| Test | Injected | Failure point | MindBridge result |
|---|---|---|---|
| Path degradation | `tc netem` loss on traffic toward 10.10.0.0/16, 0 → 8 % in 25 steps over 35 min | Loss crosses **5 %** at 18:56:31 (the SLO breach) | **Not predicted. 0 false alarms** |
| Connection-table fill | New UDP flows to the AWS test hosts, 20 → 600 flows/s over 35 min (628,781 flows) | **None reached.** The AWS firewalls' table limit is 1,048,576, not the 7,168 assumed; the peak was about 8,600 entries (< 1 %) | Correctly **no alert** (nothing was going to fail) |

## Why the loss ramp wasn't predicted

- **The probe is too coarse.** It sends 20 pings every 5 minutes, so it only sees loss in 5 %
  steps.
- **The data was noise.** As real loss rose from 0 to 5 %, the samples read
  `0, 5, 0, 5, 10, 5, 15` (two hosts, about 7 samples before the breach). That is too few
  points, too coarse, to pass the detector's trend and k-of-n gates. Refusing to alert on that
  data is the right behaviour; the probe is what needs fixing.
- **RTT stayed flat** (18–21 ms), because the injected fault was pure loss. RTT is only an early
  signal when a path degrades through congestion or rerouting.

**Fix before Session 2:** sample loss with about 200 probes per minute (0.5 % resolution,
seconds of extra traffic) instead of 20 probes every 5 minutes. That gives the trend detector
dozens of points before a 5 % breach.

## What the connection-table test taught

- **The model held a wrong limit.** The real `nf_conntrack_max` on the t4g.nano firewalls is
  1,048,576. At about 300 new flows/s per firewall with a 30 s UDP timeout, a table that size
  stays under 1 %. Filling it in a lab would need about 35,000 new flows/s per firewall.
- **So this firewall size is limited by CPU and packet rate, not by state-table size.**
  MindBridge should forecast packet rate and CPU for these VMs, not only conntrack.
- **The live sample corrected the design assumption.** The value in `design.yaml` comes from
  the collector, so it no longer depends on a guess.

Raw data: `slowburn-loss-replay.csv` (the real samples, replayable with
`python -m mindbridge replay`), and the ramp logs on the Azure firewall (now destroyed),
summarised above.
