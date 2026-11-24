"""Predict mode: run the detectors over stored or replayed samples, attach what-if impact.

Deterministic. The detector maths is in detect.py; the impact of each alert comes from the
same N-1 evaluator as `whatif` (model.py): "if this component fails, which flows break and how
long recovery takes".
"""
from __future__ import annotations

import bisect
import csv
import fnmatch
import json
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

from . import detect
from .collect import scrub
from .detect import SEVERITY_ORDER, Finding, Sample, fmt_duration, parse_duration
from .model import Model

DURATION_KEYS = {"window": "window_s", "horizon": "horizon_s", "critical": "critical_s",
                 "max_spacing": "max_spacing_s"}
DEFAULT_BASELINE_HISTORY_S = 6 * 3600
DEFAULT_LATEST_HISTORY_S = 86400


def iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- config

class SignalConfig:
    def __init__(self, data: dict):
        sig = data.get("signals") or {}
        self.targets: dict = sig.get("targets", {})
        self.collectors: dict = sig.get("collectors", {})
        self.defs: dict = sig.get("defs", {})

    @classmethod
    def from_model(cls, model: Model) -> "SignalConfig":
        return cls(model.data)

    def lookback_s(self, signal: str) -> float:
        d = self.defs.get(signal) or {}
        best = 0.0
        for det in d.get("detectors") or []:
            if "window" in det:
                best = max(best, parse_duration(det["window"]))
            elif det["type"] == "baseline_deviation":
                best = max(best, parse_duration(det.get("history", DEFAULT_BASELINE_HISTORY_S)))
            else:
                best = max(best, DEFAULT_LATEST_HISTORY_S)
        return best

    def max_lookback_s(self) -> float:
        return max([self.lookback_s(s) for s in self.defs] + [1800.0])


# ---------------------------------------------------------------- evaluation

def group(samples: list[Sample]) -> dict[tuple[str, str], list[Sample]]:
    out: dict[tuple[str, str], list[Sample]] = defaultdict(list)
    for s in sorted(samples, key=lambda s: s.ts):
        out[(s.signal, s.component)].append(s)
    return out


def rate_per_min(ser: list[Sample]) -> list[Sample]:
    """Monotonic counter -> per-minute rate. A drop (counter reset, reboot) restarts the series."""
    out = []
    for a, b in zip(ser, ser[1:]):
        dt = b.ts - a.ts
        if dt <= 0 or b.value < a.value:
            continue
        out.append(Sample(b.ts, b.signal, b.component, (b.value - a.value) * 60.0 / dt, b.unit + "/min", b.detail))
    return out


def _latest_value(ser: list[Sample] | None, at: float) -> float | None:
    if not ser:
        return None
    i = bisect.bisect_right([s.ts for s in ser], at)
    return ser[i - 1].value if i else None


def run_detector(det: dict, ser: list[Sample], paired: dict[tuple[str, str], list[Sample]],
                 now: float) -> Finding | None:
    det = dict(det)
    kind = det.pop("type")
    comp = ser[-1].component
    params = {}
    for k, v in det.items():
        if k in DURATION_KEYS:
            params[DURATION_KEYS[k]] = parse_duration(v)
        elif k in ("threshold_from", "limit_from", "history"):
            continue
        else:
            params[k] = v
    if "threshold_from" in det:
        thr = _latest_value(paired.get((det["threshold_from"], comp)), ser[-1].ts)
        if thr is None:
            return None
        params["threshold"] = thr
    if kind == "countdown":
        return detect.countdown(ser[-1], now=now, **params)
    if kind == "quota_headroom":
        lim = _latest_value(paired.get((det["limit_from"], comp)), ser[-1].ts)
        if lim is None:
            return None
        return detect.quota_headroom(ser[-1], lim, **params)
    return detect.DETECTORS[kind](ser, **params)


DEFAULT_GATE_MAX_AGE_S = 900


def gate_open(d: dict, component: str, paired: dict[tuple[str, str], list[Sample]], at: float) -> bool:
    """A signal's `gate`: its detectors run only while a gating series says they apply.

    gate.by_component maps this signal's component (fnmatch) to gating components of
    gate.signal; the gate is open when any of them has a latest value > 0 no older than
    max_age at time `at`. No pattern match, or no recent gating sample, keeps it closed.
    """
    g = d.get("gate")
    if not g:
        return True
    max_age = parse_duration(g.get("max_age", DEFAULT_GATE_MAX_AGE_S))
    for pat, gcomps in (g.get("by_component") or {}).items():
        if not fnmatch.fnmatchcase(component, pat):
            continue
        for gc in gcomps if isinstance(gcomps, list) else [gcomps]:
            ser = paired.get((g["signal"], gc)) or []
            i = bisect.bisect_right([s.ts for s in ser], at)
            if i and ser[i - 1].value > 0 and at - ser[i - 1].ts <= max_age:
                return True
        return False
    return False


def evaluate_series(signal: str, ser: list[Sample], d: dict, paired, now: float) -> list[Finding]:
    if not ser or not gate_open(d, ser[-1].component, paired, ser[-1].ts):
        return []
    if d.get("transform") == "rate_per_min":
        ser = rate_per_min(ser)
    if not ser:
        return []
    out = []
    for det in d.get("detectors") or []:
        f = run_detector(det, ser, paired, now)
        if f:
            out.append(f)
    return out


def alert_id(signal: str, component: str, detector: str) -> str:
    return f"{signal}/{component}/{detector}"


def make_alert(signal: str, component: str, f: Finding, ts: float) -> dict:
    return {
        "id": alert_id(signal, component, f.detector),
        "signal": signal,
        "component": scrub(component),
        "detector": f.detector,
        "severity": f.severity,
        "summary": f.summary,
        "eta_s": f.eta_s,
        "eta": fmt_duration(f.eta_s) if f.eta_s is not None else None,
        "deviation": f.deviation,
        "metrics": f.metrics,
        "at": iso(ts),
        "evidence": [{"ts": iso(s.ts), "value": round(s.value, 4), "unit": s.unit,
                      **({"detail": scrub(s.detail)} if s.detail else {})} for s in f.evidence],
    }


def evaluate(samples: list[Sample], cfg: SignalConfig, now: float | None = None) -> list[dict]:
    """All detectors over all series; one alert per (signal, component, detector) that fires."""
    series = group(samples)
    now = now if now is not None else (max((s.ts for s in samples), default=time.time()))
    alerts = []
    for (sig, comp), ser in series.items():
        d = cfg.defs.get(sig)
        if not d:
            continue
        lb = cfg.lookback_s(sig)
        ser = [s for s in ser if s.ts >= now - lb] if lb else ser
        if not ser:
            continue
        for f in evaluate_series(sig, ser, d, series, now):
            alerts.append(make_alert(sig, comp, f, ser[-1].ts))
    return sort_alerts(alerts)


def sort_alerts(alerts: list[dict]) -> list[dict]:
    return sorted(alerts, key=lambda a: (-SEVERITY_ORDER[a["severity"]],
                                         a["eta_s"] if a["eta_s"] is not None else float("inf"), a["id"]))


# ---------------------------------------------------------------- impact (what-if)

class Impact:
    """Caches the N-1 evaluation per model component."""

    def __init__(self, model: Model, cfg: SignalConfig):
        self.model, self.cfg = model, cfg
        self.base_removed = model.baseline_removed()
        self.baseline = model.eval_all(self.base_removed)
        self._cache: dict[str, dict] = {}

    def resolve(self, signal: str, component: str) -> list[str] | None:
        d = self.cfg.defs.get(signal) or {}
        if d.get("impact") == "none":
            return None
        for pat, target in (d.get("map") or {}).items():
            if fnmatch.fnmatchcase(component, pat):
                return list(target) if isinstance(target, list) else [target]
        if component in self.model.components:
            return [component]
        return []

    def component(self, cid: str) -> dict:
        if cid in self._cache:
            return self._cache[cid]
        m = self.model
        comp = m.components[cid]
        flows = []
        if cid in self.base_removed:
            res = {}
        else:
            res = m.eval_all(self.base_removed | {cid})
        for fid, fr in res.items():
            b = self.baseline[fid]
            if fr.same_as(b):
                continue
            flows.append({"flow": fid, "name": m.flows[fid]["name"], "weight": fr.weight, "status": fr.status,
                          "impact_pct": round(fr.impact * 100, 1), "recovery": fr.recovery,
                          "recovery_s": fr.recovery_s, "redundancy_s": fr.redundancy_s,
                          "severity": round(m.severity(fr) - m.severity(b), 2),
                          **({"note": fr.note} if fr.note else {})})
        flows.sort(key=lambda f: (-f["severity"], f["flow"]))
        total = round(sum(max(f["severity"], 0) for f in flows), 2)
        hit = [f for f in flows if f["status"] != "ok"]
        rec = max(hit, key=lambda f: _rec_rank(f), default=None)
        out = {
            "component": cid, "component_name": comp["name"], "component_status": comp["status"],
            "total_severity": total, "band": m.band(total),
            "recovery": rec["recovery"] if rec else "none",
            "recovery_s": rec["recovery_s"] if rec else None,
            "flows": flows,
            "answer": _answer(cid, comp, hit, flows),
        }
        self._cache[cid] = out
        return out

    def for_alert(self, alert: dict) -> dict:
        sig, comp = alert["signal"], alert["component"]
        d = self.cfg.defs.get(sig) or {}
        targets = self.resolve(sig, comp)
        if targets is None:
            note = d.get("impact_note", "Not a component failure.")
            blocked = self.fixes_needing(d.get("fix_need"))
            ans = note + (f" Fixes that need it: {'; '.join(blocked)}." if blocked else "")
            return {"component": None, "flows": [], "note": note, "fixes_needing_it": blocked, "answer": ans}
        targets = [t for t in targets if t in self.model.components]
        if not targets:
            note = f"{comp} is not mapped to a design component (add it to signals.defs.{sig}.map in design.yaml)"
            return {"component": None, "flows": [], "note": note, "answer": note}
        imps = [self.component(t) for t in targets]
        worst = max(imps, key=lambda i: (i["total_severity"], _rec_rank(i)))
        out = dict(worst)
        if len(imps) > 1:
            out["candidates"] = [{k: i[k] for k in ("component", "total_severity", "band", "recovery", "recovery_s",
                                                    "answer")} for i in imps]
            out["note"] = (f"The signal cannot tell which of {', '.join(targets)} is failing "
                           f"(e.g. ECMP hides the tunnel). Impact shown for the worst case, {worst['component']}.")
        return out

    def fixes_needing(self, key: str | None) -> list[str]:
        if not key:
            return []
        out = []
        for risk, fixes in self.model.fixes.items():
            for fx in fixes:
                need = (fx.get("needs") or {}).get(key)
                if need:
                    out.append(f"{fx['mitigation']} (needs {need})")
        return out


def _rec_rank(x: dict) -> tuple:
    order = {"none": 0, "auto": 1, "provider": 2, "manual": 3}
    return order[x["recovery"]], x.get("recovery_s") or 0


def _rec_text(recovery: str, s) -> str:
    if recovery == "auto":
        return f"automatic in ~{s:g} s" if s is not None else "automatic"
    return {"manual": "manual (no automatic failover)", "provider": "wait for the provider", "none": "-"}[recovery]


def _answer(cid: str, comp: dict, hit: list[dict], flows: list[dict]) -> str:
    planned = " (planned, not yet in code)" if comp["status"] == "planned" else ""
    if not hit:
        lost = [f["flow"] for f in flows if f["status"] == "ok"]
        if lost:
            return f"If {cid}{planned} fails, no flow breaks, but {', '.join(lost)} lose redundancy."
        return f"If {cid}{planned} fails, no flow breaks on its own."
    parts = []
    for f in hit:
        pct = "" if f["status"] == "broken" else f" {f['impact_pct']:g}%"
        red = f", then reduced redundancy for ~{fmt_duration(f['redundancy_s'])}" if f.get("redundancy_s") else ""
        parts.append(f"{f['flow']} {f['status']}{pct}, recovery {_rec_text(f['recovery'], f['recovery_s'])}{red}")
    return f"If {cid}{planned} fails: " + "; ".join(parts) + "."


def attach_impact(alerts: list[dict], impact: Impact) -> list[dict]:
    for a in alerts:
        a["impact"] = impact.for_alert(a)
    return alerts


# ---------------------------------------------------------------- predict over the store

def predict(store, model: Model, since_s: float = 1800, now: float | None = None) -> dict:
    cfg = SignalConfig.from_model(model)
    now = now or time.time()
    lookback = max(since_s, cfg.max_lookback_s())
    samples = store.samples(since=now - lookback)
    # fast signals use --since; signals whose detector needs a longer window keep it
    keep = [s for s in samples if s.ts >= now - max(since_s, cfg.lookback_s(s.signal))]
    alerts = attach_impact(evaluate(keep, cfg, now=now), Impact(model, cfg))
    return {
        "tool": "mindbridge predict",
        "generated": iso(now),
        "since_s": since_s,
        "samples": len(keep),
        "series": len(group(keep)),
        "collectors": [{**r, "ts": iso(r["ts"])} for r in store.last_runs()],
        "method": "Deterministic detectors (detect.py): time-to-threshold (linear fit, R² gate), EWMA baseline "
                  "deviation (k of n), flap counter, countdown, quota headroom, sustained level. Impact from the "
                  "what-if model (model.py) for the mapped component.",
        "alerts": alerts,
    }


def to_markdown(doc: dict) -> str:
    L = ["# MindBridge predict: alerts", "",
         f"Generated {doc['generated']} by `python -m mindbridge predict` over {doc['samples']} samples in "
         f"{doc['series']} series (window {fmt_duration(doc['since_s'])}; longer-window signals keep theirs). "
         "Every number comes from the deterministic detectors and the what-if model; nothing is produced by AI.", ""]
    alerts = doc["alerts"]
    if not alerts:
        L += ["**No alerts.**", ""]
    else:
        L += ["| Severity | Signal | Component | Detector | Finding | ETA | If it fails |", "|---|---|---|---|---|---|---|"]
        for a in alerts:
            L.append(f"| {a['severity']} | {a['signal']} | {a['component']} | {a['detector']} | "
                     f"{a['summary'].replace('|', '/')} | {a['eta'] or '-'} | {a['impact']['answer'].replace('|', '/')} |")
        L.append("")
        for a in alerts:
            L += [f"## {a['id']}", "", f"- severity: **{a['severity']}**, last sample {a['at']}",
                  f"- finding: {a['summary']}"]
            if a["eta_s"] is not None:
                L.append(f"- ETA: {a['eta']} ({a['eta_s']:g} s)")
            if a["deviation"] is not None:
                L.append(f"- deviation: {a['deviation']:g}")
            imp = a["impact"]
            L.append(f"- impact: {imp['answer']}")
            if imp.get("note") and imp.get("component"):
                L.append(f"- note: {imp['note']}")
            L.append("- evidence: " + ", ".join(f"{e['ts']} = {e['value']:g} {e['unit']}" for e in a["evidence"]))
            L.append("")
    if doc.get("collectors"):
        L += ["## Collectors (last run)", "", "| Collector | Status | Samples | Time | Message |", "|---|---|---|---|---|"]
        for r in doc["collectors"]:
            L.append(f"| {r['collector']} | {r['status']} | {r['samples']} | {r['duration_s']:g} s | "
                     f"{(r['message'] or '').replace('|', '/')} |")
        L.append("")
    return "\n".join(L)


def write(doc: dict, out_dir: Path) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = doc["generated"].replace("-", "").replace(":", "")
    md, js = out_dir / f"alerts-{stamp}.md", out_dir / f"alerts-{stamp}.json"
    md.write_text(to_markdown(doc))
    js.write_text(json.dumps(doc, indent=2) + "\n")
    return md, js


# ---------------------------------------------------------------- replay

def _ts(v: str) -> float:
    v = v.strip()
    try:
        return float(v)
    except ValueError:
        return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()


def load_fixture(path: Path | str) -> tuple[list[Sample], list[dict]]:
    """CSV: ts,signal,component,value,unit,event. A row with event=failure marks the failure
    point of (signal, component); its value may be empty. Lines starting with # are comments."""
    samples, failures = [], []
    with open(path) as fh:
        rows = csv.DictReader(ln for ln in fh if ln.strip() and not ln.startswith("#"))
        for r in rows:
            ts = _ts(r["ts"])
            ev = (r.get("event") or "").strip()
            if ev == "failure":
                failures.append({"ts": ts, "signal": r["signal"], "component": r["component"],
                                 "note": (r.get("note") or "").strip()})
                if not (r.get("value") or "").strip():
                    continue
            samples.append(Sample(ts, r["signal"], r["component"], float(r["value"]), r.get("unit") or ""))
    return samples, failures


def replay(path: Path | str, model: Model) -> dict:
    """Stream the fixture sample by sample through the detectors, as `watch` would see it.

    lead time = failure time - first alert time, for alerts on the failing component.
    A false alarm is an alert on a component that has no failure in the fixture, or one that
    fires on the failing component but only after it has recovered (not used here).
    """
    cfg = SignalConfig.from_model(model)
    samples, failures = load_fixture(path)
    series = group(samples)
    first: dict[str, dict] = {}
    history: dict[str, list] = defaultdict(list)   # aid -> [(t, severity, eta_s)]
    for (sig, comp), ser in series.items():
        d = cfg.defs.get(sig)
        if not d:
            continue
        lb = cfg.lookback_s(sig)
        for i in range(len(ser)):
            t = ser[i].ts
            prefix = [s for s in ser[: i + 1] if not lb or s.ts >= t - lb]
            # paired series (limits) are read at ts <= t by _latest_value, so no look-ahead
            for f in evaluate_series(sig, prefix, d, series, t):
                aid = alert_id(sig, comp, f.detector)
                history[aid].append((t, f.severity, f.eta_s))
                if aid not in first:
                    first[aid] = make_alert(sig, comp, f, t)
    alerts = attach_impact(sort_alerts(list(first.values())), Impact(model, cfg))
    by_comp = defaultdict(list)
    for fl in failures:
        by_comp[fl["component"]].append(fl)
    false_alarms, late = [], []
    for a in alerts:
        t = _ts(a["at"])
        fls = by_comp.get(a["component"])
        if not fls:
            a["classification"] = "false_alarm"
            false_alarms.append(a["id"])
        elif t <= min(f["ts"] for f in fls):
            a["classification"] = "early_warning"
        else:
            a["classification"] = "late"
            late.append(a["id"])
    results = []
    for fl in failures:
        early = [a for a in alerts if a["component"] == fl["component"] and a["classification"] == "early_warning"]
        first_a = min(early, key=lambda a: _ts(a["at"]), default=None)
        r = {"failure_at": iso(fl["ts"]), "signal": fl["signal"], "component": fl["component"], "note": fl["note"],
             "first_alert_at": first_a["at"] if first_a else None,
             "first_alert": first_a["id"] if first_a else None,
             "lead_time_s": round(fl["ts"] - _ts(first_a["at"]), 1) if first_a else None,
             "detected_by": [a["id"] for a in early]}
        crit = [t for a in early for (t, sev, _) in history[a["id"]] if sev == "critical" and t <= fl["ts"]]
        if crit:
            r["first_critical_at"] = iso(min(crit))
            r["critical_lead_time_s"] = round(fl["ts"] - min(crit), 1)
        etas = [a for a in early if a["detector"] == "time_to_threshold" and a["eta_s"] is not None]
        if etas:
            e0 = min(etas, key=lambda a: _ts(a["at"]))
            r["eta_at_first_alert_s"] = e0["eta_s"]
            # predicted crossing minus actual failure: + means it predicted too late
            r["eta_error_s"] = round(_ts(e0["at"]) + e0["eta_s"] - fl["ts"], 1)
            track = [(t, eta) for (t, _, eta) in history[e0["id"]] if t < fl["ts"] and eta]
            if track:
                mid = min(track, key=lambda x: abs(x[0] - (_ts(e0["at"]) + fl["ts"]) / 2))
                r["eta_error_mid_s"] = round(mid[0] + mid[1] - fl["ts"], 1)
                r["eta_error_last_s"] = round(track[-1][0] + track[-1][1] - fl["ts"], 1)
        results.append(r)
    return {"fixture": Path(path).name, "samples": len(samples), "series": len(series), "failures": results,
            "alerts": alerts, "false_alarms": false_alarms, "late_alerts": late}


def _signed(s) -> str:
    if s is None:
        return "-"
    return ("+" if s >= 0 else "-") + fmt_duration(abs(s)).replace("now", "0 s")


def replay_text(res: dict) -> str:
    L = [f"replay {res['fixture']}: {res['samples']} samples, {res['series']} series"]
    for f in res["failures"]:
        if f["lead_time_s"] is None:
            L.append(f"  failure {f['component']} {f['signal']} at {f['failure_at']}: NOT predicted")
            continue
        s = (f"  failure {f['component']} {f['signal']} at {f['failure_at']}: first alert {f['first_alert_at']} "
             f"({f['first_alert']}), lead time {fmt_duration(f['lead_time_s'])} ({f['lead_time_s']:g} s)")
        L.append(s)
        if "first_critical_at" in f:
            L.append(f"    critical from {f['first_critical_at']} ({fmt_duration(f['critical_lead_time_s'])} before)")
        if "eta_error_s" in f:
            L.append(f"    ETA at first alert {fmt_duration(f['eta_at_first_alert_s'])}; predicted crossing minus "
                     f"actual: {_signed(f['eta_error_s'])} at first alert, {_signed(f.get('eta_error_mid_s'))} "
                     f"half-way, {_signed(f.get('eta_error_last_s'))} at the last sample before failure")
    if not res["failures"]:
        L.append("  no failure marked in this fixture")
    for a in res["alerts"]:
        L.append(f"  [{a['classification']}] {a['at']} {a['severity']:8} {a['id']}: {a['summary']}")
        L.append(f"      impact: {a['impact']['answer']}")
    L.append(f"  false alarms: {len(res['false_alarms'])}")
    return "\n".join(L)
