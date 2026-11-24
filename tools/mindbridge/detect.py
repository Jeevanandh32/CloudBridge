"""Predict-mode detectors. Pure functions over timestamped samples; no I/O, no AI.

Each detector takes the samples of one (signal, component) series, oldest first, and returns
a Finding when it sees a warning sign, or None. predict.py turns findings into alerts and adds
the what-if impact.
"""
from __future__ import annotations

import math
import re
from dataclasses import dataclass, field

SEVERITY_ORDER = {"warning": 1, "critical": 2}


@dataclass(frozen=True)
class Sample:
    ts: float          # unix seconds, UTC
    signal: str
    component: str     # the collector's component id (mapped to a model component later)
    value: float
    unit: str = ""
    detail: str = ""


@dataclass
class Finding:
    detector: str
    severity: str                 # warning | critical
    summary: str
    eta_s: float | None = None    # seconds from the last sample to the threshold
    deviation: float | None = None
    metrics: dict = field(default_factory=dict)
    evidence: list = field(default_factory=list)   # the samples that triggered it


_DUR = re.compile(r"^\s*(\d+(?:\.\d+)?)\s*([smhdw]?)\s*$")
_DUR_MULT = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}


def parse_duration(v) -> float:
    """'30m' -> 1800.0; numbers are seconds."""
    if isinstance(v, (int, float)):
        return float(v)
    m = _DUR.match(str(v))
    if not m:
        raise ValueError(f"bad duration {v!r}")
    return float(m.group(1)) * _DUR_MULT[m.group(2)]


def fmt_duration(s: float | None) -> str:
    if s is None:
        return "-"
    if s <= 0:
        return "now"
    if s < 120:
        return f"{s:.0f} s"
    if s < 7200:
        return f"{s / 60:.0f} min"
    if s < 172800:
        return f"{s / 3600:.1f} h"
    return f"{s / 86400:.1f} d"


def _window(samples: list[Sample], window_s: float | None) -> list[Sample]:
    if not samples or window_s is None:
        return list(samples)
    t_end = samples[-1].ts
    return [s for s in samples if s.ts >= t_end - window_s]


def linreg(xs: list[float], ys: list[float]) -> tuple[float, float, float]:
    """Least squares: returns (slope, intercept, r2). r2 is 0 for a flat series."""
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    if sxx == 0:
        return 0.0, my, 0.0
    slope = sxy / sxx
    intercept = my - slope * mx
    r2 = (sxy * sxy) / (sxx * syy) if syy > 0 else 0.0
    return slope, intercept, r2


# ---------------------------------------------------------------- time to threshold

def time_to_threshold(samples: list[Sample], *, threshold: float, direction: str = "up",
                      window_s: float = 1800, min_samples: int = 8, r2_min: float = 0.6,
                      horizon_s: float = 6 * 3600, critical_s: float = 1800,
                      beyond_median: int | None = None, max_spacing_s: float | None = None,
                      min_rise: float = 0.0) -> Finding | None:
    """Linear trend over a sliding window -> ETA until the value crosses `threshold`.

    direction "up": alert when rising towards a ceiling (conntrack %); "down": falling towards a
    floor (free IPs). No alert unless there are `min_samples` points, the fit explains at least
    `r2_min` of the variance and the projected crossing is within `horizon_s`.

    Gates for noisy, sampled signals such as ping loss:
    - beyond_median: "threshold already reached" needs `min_samples` points and the median of the
      last N samples beyond the threshold (one noisy or 100 % sample is not a trend).
    - max_spacing_s: the data must be at least this fine (median gap between samples); coarser
      data gives no alert from this detector.
    - min_rise: the fitted line must move at least this much across the window.
    """
    win = _window(samples, window_s)
    if not win:
        return None
    last = win[-1]
    enough = len(win) >= min_samples
    if max_spacing_s is not None and len(win) > 1:
        gaps = sorted(b.ts - a.ts for a, b in zip(win, win[1:]))
        if gaps[len(gaps) // 2] > max_spacing_s:
            return None
    if beyond_median:
        tail = sorted(s.value for s in win[-beyond_median:])
        probe = tail[len(tail) // 2]
        gate = enough and len(win) >= beyond_median
    else:
        probe, gate = last.value, True
    beyond = probe >= threshold if direction == "up" else probe <= threshold
    if beyond and gate:
        return Finding("time_to_threshold", "critical",
                       f"at {last.value:g} {last.unit}, threshold {threshold:g} reached",
                       eta_s=0.0, metrics={"threshold": threshold, "last": last.value},
                       evidence=win[-min(len(win), 6):])
    if not enough or beyond:
        return None
    t0 = win[0].ts
    xs = [s.ts - t0 for s in win]
    ys = [s.value for s in win]
    slope, intercept, r2 = linreg(xs, ys)
    toward = slope > 0 if direction == "up" else slope < 0
    if not toward or r2 < r2_min:
        return None
    if abs(slope) * (xs[-1] - xs[0]) < min_rise:
        return None
    fitted_now = intercept + slope * xs[-1]
    eta = (threshold - fitted_now) / slope
    if eta < 0:
        eta = 0.0
    if eta > horizon_s:
        return None
    sev = "critical" if eta <= critical_s else "warning"
    per_h = slope * 3600
    return Finding("time_to_threshold", sev,
                   f"{direction == 'up' and 'rising' or 'falling'} {abs(per_h):.3g} {last.unit}/h, "
                   f"reaches {threshold:g} in {fmt_duration(eta)} (R² {r2:.2f}, {len(win)} samples)",
                   eta_s=round(eta, 1),
                   metrics={"threshold": threshold, "slope_per_h": round(per_h, 4), "r2": round(r2, 3),
                            "samples": len(win), "last": last.value, "fitted_now": round(fitted_now, 3)},
                   evidence=win[-min(len(win), 6):])


# ---------------------------------------------------------------- baseline deviation

def baseline_deviation(samples: list[Sample], *, alpha: float = 0.1, warmup: int = 12,
                       k_sigma: float = 3.0, min_delta: float = 0.0, min_std: float = 1e-9,
                       k: int = 3, n: int = 5, direction: str = "up",
                       update_band: float = 2.0) -> Finding | None:
    """EWMA mean/variance per signal; alert when k of the last n samples deviate.

    A sample deviates when it is more than k_sigma standard deviations AND more than min_delta
    (absolute) away from the baseline, in `direction` ("up", "down" or "both"). Only samples
    within `update_band` standard deviations (either side) update the baseline, so a slow creep
    cannot teach the baseline (mean or variance) that it is normal. The first `warmup` samples
    only build the baseline. The price: after a deliberate permanent change (a new route with a
    higher RTT) the baseline does not re-learn; clear that series from the store.
    """
    if len(samples) <= warmup:
        return None
    mean = samples[0].value
    var = 0.0
    flags: list[bool] = []
    states = []
    for i, s in enumerate(samples):
        if i < warmup:
            if i > 0:
                d = s.value - mean
                mean += alpha * d
                var = (1 - alpha) * (var + alpha * d * d)
            continue
        std = max(math.sqrt(var), min_std)
        d = s.value - mean
        if direction == "up":
            dev = d
        elif direction == "down":
            dev = -d
        else:
            dev = abs(d)
        flagged = dev > k_sigma * std and dev > min_delta
        flags.append(flagged)
        states.append((s, mean, std, d))
        if abs(d) <= update_band * std:
            mean += alpha * d
            var = (1 - alpha) * (var + alpha * d * d)
    recent = flags[-n:]
    hits = sum(recent)
    if hits < k:
        return None
    s = states[-1][0]
    # report against the baseline the last flagged sample was compared with
    _, mean_at, std_at, d = next(st for st, fl in zip(reversed(states), reversed(flags)) if fl)
    ev = [st[0] for st, fl in zip(states[-n:], recent) if fl]
    sev = "critical" if hits == len(recent) and abs(d) > 2 * k_sigma * std_at else "warning"
    return Finding("baseline_deviation", sev,
                   f"{hits} of last {len(recent)} samples off baseline {mean_at:.3g} {s.unit} "
                   f"(std {std_at:.3g}); latest {s.value:g} {s.unit}",
                   deviation=round(d, 4),
                   metrics={"baseline_mean": round(mean_at, 4), "baseline_std": round(std_at, 4),
                            "k": hits, "n": len(recent), "latest": s.value,
                            "sigma": round(d / std_at, 2) if std_at else None},
                   evidence=ev)


# ---------------------------------------------------------------- flap counter

def flap_counter(samples: list[Sample], *, window_s: float = 1800, max_changes: int = 4) -> Finding | None:
    """Counts state changes (value differs from the previous sample) inside the window."""
    win = _window(samples, window_s)
    if len(samples) > len(win) and win:
        # include the sample just before the window so a change at its start counts
        win = [samples[len(samples) - len(win) - 1]] + win
    changes = [b for a, b in zip(win, win[1:]) if a.value != b.value]
    if len(changes) < max_changes:
        return None
    sev = "critical" if len(changes) >= 2 * max_changes else "warning"
    last = win[-1]
    return Finding("flap_counter", sev,
                   f"{len(changes)} state changes in {fmt_duration(window_s)}; now {last.value:g}",
                   deviation=float(len(changes)),
                   metrics={"changes": len(changes), "window_s": window_s, "max_changes": max_changes,
                            "current": last.value},
                   evidence=changes[-8:])


# ---------------------------------------------------------------- countdown

def countdown(sample: Sample, *, now: float, warn_days: float = 30, critical_days: float = 7) -> Finding | None:
    """sample.value = days left when the sample was taken. Ages it to `now`."""
    days = sample.value - (now - sample.ts) / 86400.0
    if days > warn_days:
        return None
    sev = "critical" if days <= critical_days else "warning"
    return Finding("countdown", sev, f"{days:.1f} days left (warn at {warn_days:g}, critical at {critical_days:g})",
                   eta_s=round(max(days, 0) * 86400, 0),
                   metrics={"days_left": round(days, 2), "warn_days": warn_days, "critical_days": critical_days},
                   evidence=[sample])


# ---------------------------------------------------------------- quota headroom

def quota_headroom(used: Sample, limit: float, *, warn_free: float = 1, critical_free: float = 0) -> Finding | None:
    free = limit - used.value
    if free > warn_free:
        return None
    sev = "critical" if free <= critical_free else "warning"
    return Finding("quota_headroom", sev, f"{used.value:g} of {limit:g} used, {free:g} free",
                   deviation=free, metrics={"used": used.value, "limit": limit, "free": free,
                                            "warn_free": warn_free}, evidence=[used])


# ---------------------------------------------------------------- level (sustained static threshold)

def level(samples: list[Sample], *, threshold: float, direction: str = "above", k: int = 1, n: int = 1,
          severity: str = "warning") -> Finding | None:
    """k of the last n samples above (or below) a fixed threshold, e.g. Pending pods > 0."""
    recent = samples[-n:]
    hit = [s for s in recent if (s.value > threshold if direction == "above" else s.value < threshold)]
    if len(hit) < k or not recent:
        return None
    last = recent[-1]
    return Finding("level", severity,
                   f"{len(hit)} of last {len(recent)} samples {direction} {threshold:g}; latest {last.value:g} {last.unit}"
                   + (f" ({last.detail})" if last.detail else ""),
                   deviation=round(last.value - threshold, 4),
                   metrics={"threshold": threshold, "k": len(hit), "n": len(recent), "latest": last.value},
                   evidence=hit)


DETECTORS = {
    "time_to_threshold": time_to_threshold,
    "baseline_deviation": baseline_deviation,
    "flap_counter": flap_counter,
    "countdown": countdown,
    "quota_headroom": quota_headroom,
    "level": level,
}
