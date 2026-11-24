"""N-1 sweep: remove each component in turn and evaluate every flow."""
from __future__ import annotations

import json
from pathlib import Path

from .model import Model

KIND_SECTION = {
    "vm": "infrastructure",
    "managed": "infrastructure",
    "external": "management",
    "config": "config",
}
MGMT_FLOWS = {"change-path", "domain-control"}


def _affected(model: Model, baseline: dict, results: dict) -> tuple[list[dict], float]:
    affected = []
    total = 0.0
    for fid, fr in results.items():
        b = baseline[fid]
        if fr.same_as(b):
            continue
        sev = round(model.severity(fr) - model.severity(b), 2)
        total += max(sev, 0.0)
        d = fr.to_dict()
        d["severity"] = sev
        d["flow_name"] = model.flows[fid]["name"]
        affected.append(d)
    affected.sort(key=lambda d: (-d["severity"], d["flow"]))
    return affected, round(total, 2)


def mins(s: float) -> str:
    return f"{s:g} s" if s < 120 else f"{s / 60:.0f} min"


def summary_text(worst: dict | None, redundancy_s: float | None, affected: list[dict] | None = None) -> str:
    """'users recover in ~30 s; redundancy is reduced for ~14 min'"""
    if not worst:
        s = "no flow loses packets"
    elif worst["recovery"] == "auto":
        s = f"users recover in ~{mins(worst['recovery_s'])}" if worst["recovery_s"] is not None else "users recover automatically"
    elif worst["recovery"] == "manual":
        s = "users stay affected until someone fixes it"
    elif worst["recovery"] == "provider":
        s = "users stay affected until the provider restores it"
    else:
        s = "no flow loses packets"
    if redundancy_s:
        s += f"; redundancy is reduced for ~{mins(redundancy_s)}"
    elif affected and any(a.get("redundancy_lost_pct") for a in affected):
        s += "; redundancy is reduced until the component is fixed"
    return s


def sweep(model: Model, facts=None) -> dict:
    base_removed = model.baseline_removed()
    baseline = model.eval_all(base_removed)
    usage = model.constraint_usage(facts.facts if facts else None)
    rows = []
    for cid, comp in model.components.items():
        if cid in base_removed:
            continue
        removed = base_removed | {cid}
        per_mode = {}
        for fm in model.modes_for([cid]):
            affected, total = _affected(model, baseline, model.eval_all(removed, fm))
            per_mode[fm] = (affected, total)
        # the row is scored on its worst failure mode; every mode is reported, labelled
        main_mode = max(per_mode, key=lambda m: (per_mode[m][1], m == "silent"))
        affected, total = per_mode[main_mode]
        worst = _worst(affected)
        red_s = max((a["redundancy_s"] or 0 for a in affected), default=0) or None
        section = KIND_SECTION[comp["kind"]]
        if section != "config" and affected and all(a["flow"] in MGMT_FLOWS for a in affected if a["status"] != "ok"):
            section = "management"
        modes_out = {}
        if main_mode is not None:
            causes = comp.get("failure_causes") or {}
            for fm, (aff, tot) in per_mode.items():
                w = _worst(aff)
                rs = max((a["redundancy_s"] or 0 for a in aff), default=0) or None
                modes_out[fm] = {
                    "name": model.failure_modes[fm]["name"],
                    "cause": causes.get(fm, model.failure_modes[fm]["examples"]),
                    "severity": tot,
                    "worst_status": w["status"] if w else "ok",
                    "recovery": w["recovery"] if w else "none",
                    "recovery_s": w["recovery_s"] if w else (0.0 if aff else None),
                    "redundancy_s": rs,
                    "summary": summary_text(w, rs, aff),
                    "flows": [{k: a[k] for k in ("flow", "status", "impact_pct", "recovery", "recovery_s",
                                                 "redundancy_lost_pct", "redundancy_s", "severity")} for a in aff],
                }
        rows.append({
            "component": cid,
            "name": comp["name"],
            "cloud": comp["cloud"],
            "layer": comp["layer"],
            "planned_layer": comp.get("planned_layer"),
            "status": comp["status"],
            "kind": comp["kind"],
            "section": section,
            "severity": total,
            "band": model.band(total),
            "worst_status": worst["status"] if worst else "ok",
            "recovery": worst["recovery"] if worst else "none",
            "recovery_s": worst["recovery_s"] if worst else None,
            "redundancy_s": red_s,
            "summary": summary_text(worst, red_s, affected) if affected else "",
            "failure_mode": main_mode,
            "failure_modes": modes_out,
            "flows": affected,
            "transition_risk": _transition(model, comp),
            "risk": comp.get("risk"),
            "fixes": model.fixes_for(comp.get("risk"), usage) if comp.get("risk") else [],
        })
    rows.sort(key=lambda r: (-r["severity"], r["component"]))
    for i, r in enumerate(rows, 1):
        r["rank"] = i
    return {
        "baseline": {fid: fr.to_dict() for fid, fr in baseline.items()},
        "baseline_absent": sorted(base_removed),
        "constraints": usage,
        "rows": rows,
    }


def _transition(model: Model, comp: dict) -> dict | None:
    tr = comp.get("transition_risk")
    if not tr:
        return None
    return {**tr, "window_s": model.recovery_seconds(tr["window"]),
            "source": model.recovery_times[tr["window"]]["source"]}


def _worst(affected: list[dict]) -> dict | None:
    order = {"ok": 0, "degraded": 1, "broken": 2}
    hit = [a for a in affected if a["status"] != "ok"]
    if not hit:
        return None
    return max(hit, key=lambda a: (order[a["status"]], a["severity"]))


def build_report(model: Model, facts, log, problems) -> dict:
    result = sweep(model, facts)
    return {
        "tool": "mindbridge whatif",
        "method": "N-1: remove each component, evaluate every flow. severity = flow weight x impact x recovery penalty",
        "scoring": model.scoring,
        "recovery_times": model.recovery_times,
        "flows": [{"id": f["id"], "name": f["name"], "weight": f["weight"]} for f in model.flows.values()],
        "facts": facts.facts,
        "fact_checks": log,
        "address_problems": problems,
        "unresolved": [{"fact": k, **v} for k, v in facts.facts.items() if not v["resolved"]],
        **result,
    }


# ---------------- markdown ----------------

def _rec(r) -> str:
    if r["recovery"] == "auto":
        s = f"auto ~{r['recovery_s']:g} s" if r["recovery_s"] is not None else "auto"
    else:
        s = {"none": "-", "provider": "wait for provider", "manual": "manual"}[r["recovery"]]
    if r.get("redundancy_s"):
        s += f"; reduced redundancy ~{mins(r['redundancy_s'])}"
    return s


def _modes_cell(row) -> str:
    fms = row.get("failure_modes") or {}
    if not fms:
        return ""
    return "<br>".join(f"**{m['name']}** ({m['cause']}): {m['summary']}" for m in fms.values())


def _flows_cell(row) -> str:
    parts = []
    for f in row["flows"]:
        if f["status"] == "ok":
            parts.append(f"{f['flow']}: {f['note'] or 'loses redundancy'}")
            continue
        pct = "" if f["status"] == "broken" else f" {f['impact_pct']:g}%"
        parts.append(f"{f['flow']} {f['status']}{pct}")
    return "; ".join(parts) or "none"


def _fix_cell(row) -> str:
    fixes = row["fixes"]
    if not fixes:
        return ""
    ok = [f for f in fixes if not f["blocked"]]
    best = ok[0] if ok else fixes[0]
    s = f"{best['mitigation']} ({_usd(best['usd_per_hr'])})"
    blocked = [f for f in fixes if f["blocked"]]
    if blocked:
        s += "; blocked: " + "; ".join(f"{b['mitigation']} ({_usd(b['usd_per_hr'])}) [{', '.join(b['blocked_by'])}]" for b in blocked)
    return s


def _usd(x) -> str:
    return "no extra cost" if not x else f"~${x:g}/hr"


def _table(rows) -> list[str]:
    out = ["| # | Component | Cloud | Layer | Severity | Worst | Recovery | Flows affected | BGP failure modes | Suggested fix |",
           "|---|---|---|---|---|---|---|---|---|---|"]
    for i, r in enumerate(rows, 1):
        layer = f"planned ({r['planned_layer']}), not yet in code" if r["status"] == "planned" else r["layer"]
        out.append(
            f"| {i} | **{r['component']}** {r['name']} | {r['cloud']} | {layer} | "
            f"{r['severity']:g} ({r['band']}) | {r['worst_status']} | {_rec(r)} | {_flows_cell(r)} | "
            f"{_modes_cell(r)} | {_fix_cell(r)} |"
        )
    return out


def to_markdown(report: dict) -> str:
    rows = report["rows"]
    L = ["# MindBridge what-if report (N-1)", "",
         "Generated by `python -m mindbridge whatif` from `tools/mindbridge/design.yaml` and the "
         "Terraform. Every number here comes from the deterministic model; nothing is "
         "produced by AI.", "",
         f"Method: {report['method']}. Recovery penalty: manual "
         f"{report['scoring']['recovery_penalty']['manual']}, provider "
         f"{report['scoring']['recovery_penalty']['provider']}, auto 1 + seconds/"
         f"{report['scoring']['recovery_penalty']['auto_per_s']} (cap "
         f"{report['scoring']['recovery_penalty']['auto_cap']}). Bands: high >= "
         f"{report['scoring']['bands']['high']}, medium >= {report['scoring']['bands']['medium']}.", "",
         "Components marked **planned** come from `docs/plan.md` (aws/eks, azure/aks, "
         "global/dns are not yet in code).", "",
         "BGP paths are scored for two failure modes, and both are shown. A **clean withdrawal** "
         "(config mismatch, admin shutdown, a peer NOTIFICATION, a VPN connection replaced through the API) "
         "moves the flows at once. A **silent failure** (instance reboot or crash) leaves the flows on the "
         "lost tunnels waiting for the BGP hold timer. The row's severity uses the worse one. The "
         f"**reduced-redundancy window** is the time a component stays degraded after users have recovered; "
         f"it adds weight x share lost x min({report['scoring']['reduced_redundancy']['cap']}, "
         f"seconds/{report['scoring']['reduced_redundancy']['per_s']}) to the severity.", "",
         "Recovery times marked `source: measured 2026-11-23` come from Session 1 "
         "(`docs/runs/test3-summary.md`, `test4-summary.md`, `slowburn-summary.md`).", ""]

    bad = [f for f in report["baseline"].values() if f["status"] != "ok"]
    L.append("## Baseline")
    L.append("")
    if bad:
        L.append("The code as written already degrades these flows (no component removed):")
        L += [f"- {f['flow']}: {f['status']} {f['impact_pct']:g}%" for f in bad]
    else:
        L.append(f"All {len(report['baseline'])} flows OK with every component up.")
    L.append("")

    for title, sec, blurb in [
        ("Infrastructure single points of failure", "infrastructure",
         "A VM, managed service or tunnel fails. Worst first."),
        ("Configuration single points (what precheck guards)", "config",
         "A route, propagation or toggle is removed by a change. `mindbridge precheck` blocks these in a plan."),
        ("Management plane", "management", "The change path: state, control planes, registrar. Data paths keep running."),
    ]:
        sec_rows = [r for r in rows if r["section"] == sec and r["flows"]]
        L += [f"## {title}", "", blurb, ""] + _table(sec_rows) + [""]

    trans = [r for r in rows if r.get("transition_risk")]
    if trans:
        L += ["## Change (transition) risks", "",
              "Changing these on live traffic is itself disruptive, whatever the end state. `mindbridge precheck` "
              "blocks any change to them outside a maintenance window.", "",
              "| Component | Attribute | Window | Measured | Note |", "|---|---|---|---|---|"]
        for r in trans:
            t = r["transition_risk"]
            ok = t.get("success_pct")
            meas = f"{ok[0]}-{ok[1]} % of new flows ok" if ok else ""
            L.append(f"| **{r['component']}** {r['name']} | `{t['attribute']}` | ~{mins(t['window_s'])} | {meas} | "
                     f"{t['summary']} |")
        L.append("")

    quiet = [r["component"] for r in rows if not r["flows"]]
    if quiet:
        L += ["## No flow impact on their own", "",
              "These only matter when something else has already failed (N-2), e.g. a DNS health-check "
              "system when the AWS path is also down, or (appliance mode) only for flow kinds that don't "
              "exist yet: " + ", ".join(quiet), ""]

    c = report["constraints"]
    L += ["## Constraints used for fixes", ""]
    for k in ("azure_public_ips", "azure_bseries_vcpu"):
        if k in c:
            L.append(f"- {k}: {c[k]['used']} used of {c[k]['limit']} ({c[k]['free']} free)")
    if "budget" in c:
        b = c["budget"]
        L.append(f"- budget: ${b['total_usd']} total, ${b['planned_spend_usd']} planned, "
                 f"${b['max_extra_usd_per_hr']}/hr headroom for fixes")
    L.append("")

    L += ["## Facts read from Terraform", "", "| Fact | Value | Source | Note |", "|---|---|---|---|"]
    for k, v in report["facts"].items():
        if not v["resolved"]:
            continue
        val = json.dumps(v["value"]) if not isinstance(v["value"], str) else v["value"]
        note = ("derived: " if v.get("derived") else "") + (v.get("detail") or "")
        L.append(f"| {k} | `{val}` | {v['source']} | {note.replace('|', '/')} |")
    L.append("")
    L += ["## Could not resolve from Terraform", "", "| Fact | Assumed | Source | Why |", "|---|---|---|---|"]
    for u in report["unresolved"]:
        L.append(f"| {u['fact']} | `{u['value']}` | {u['source']} | {u['detail'].replace('|', '/')} |")
    L.append("")
    if report["address_problems"]:
        L += ["## Model addresses not found in code", ""]
        L += [f"- {p['component']}: `{p['address']}` ({p['problem']})" for p in report["address_problems"]]
        L.append("")
    L += ["## Model checks against code", ""]
    L += [f"- {x['fact']} = `{x['value']}`: {x['status']}, {x['effect']}" for x in report["fact_checks"]]
    L.append("")
    return "\n".join(L)


def write(report: dict, out_dir: Path) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    md = out_dir / "whatif-report.md"
    js = out_dir / "whatif-report.json"
    md.write_text(to_markdown(report))
    js.write_text(json.dumps(report, indent=2, default=str) + "\n")
    return md, js
