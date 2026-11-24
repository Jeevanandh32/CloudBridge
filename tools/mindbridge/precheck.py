"""Check a Terraform plan against the model before it is applied.

Input is the JSON from `terraform show -json <planfile>`. Only resource_changes is read:
address, change.actions, change.before / change.after / change.after_unknown.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import yaml

from .model import PKG_DIR, Model, parse_tf_entry

RULES_PATH = PKG_DIR / "rules.yaml"
ORDER = {"ok": 0, "degraded": 1, "broken": 2}


def load_rules(path: Path | str = RULES_PATH) -> dict:
    with open(path) as fh:
        return yaml.safe_load(fh)


def classify(actions: list[str]) -> str:
    a = list(actions)
    if a in (["delete", "create"], ["create", "delete"]):
        return "replace"
    if a == ["delete"]:
        return "delete"
    if a == ["update"]:
        return "update"
    if a == ["create"]:
        return "create"
    if a == ["read"]:
        return "read"
    return "no-op"


def strip_module(address: str) -> str:
    """module.x.aws_instance.fw[0] -> aws_instance.fw[0]"""
    while address.startswith("module."):
        parts = address.split(".", 2)
        address = parts[2] if len(parts) == 3 else address
        address = re.sub(r"^\[[^\]]*\]\.", "", address)
    return address


def base(address: str) -> str:
    return re.sub(r"\[.*\]$", "", address)


def pattern_match(pattern: str, address: str) -> bool:
    if pattern == "*":
        return True
    if pattern == address:
        return True
    if "[" not in pattern:
        return base(address) == pattern
    rx = re.escape(pattern).replace(r"\[\*\]", r"\[[^\]]+\]")
    return re.fullmatch(rx, address) is not None


def changed_attrs(change: dict) -> dict[str, tuple]:
    before = change.get("before") or {}
    after = change.get("after") or {}
    unknown = change.get("after_unknown") or {}
    out = {}
    for k in set(before) | set(after) | set(unknown):
        b = before.get(k)
        a = "(known after apply)" if unknown.get(k) is True else after.get(k)
        if a != b:
            out[k] = (b, a)
    return out


def infer_layer(addresses: list[str], roots: dict) -> str | None:
    cands = [name for name, root in roots.items()
             if all(base(a) in root.resources for a in addresses)]
    return cands[0] if len(cands) == 1 else None


def mapped_components(model: Model, address: str, layer: str | None) -> list[str]:
    out = []
    for cid, c in model.components.items():
        if c["status"] == "planned":
            continue
        for entry in c["tf"]:
            elayer, eaddr = parse_tf_entry(entry, c["layer"])
            if layer and elayer != layer:
                continue
            if eaddr == address or ("[" not in eaddr and base(address) == eaddr):
                out.append(cid)
                break
    return out


def resource_type(address: str) -> str:
    return address.split(".", 1)[0]


def _rule_applies(rule: dict, address: str, action: str, attrs: dict) -> bool:
    if "match_type" in rule:
        if resource_type(address) != rule["match_type"]:
            return False
    elif not pattern_match(rule["match"], address):
        return False
    if action not in rule["actions"]:
        return False
    if action == "update":
        attr = rule.get("attribute")
        if not attr or attr not in attrs:
            return False
        b, a = attrs[attr]
        if "from" in rule and b != rule["from"]:
            return False
        if "to" in rule and a != rule["to"]:
            return False
    return True


def _expected_mode(modes: list[str]) -> str:
    """A scenario is a clean BGP withdrawal only if every change in it is; else assume silent."""
    return "clean" if modes and all(m == "clean" for m in modes) else "silent"


def _mode_summary(model: Model, baseline: dict, results: dict) -> list[dict]:
    out = []
    for fid, fr in results.items():
        b = baseline[fid]
        if fr.same_as(b):
            continue
        out.append({"flow": fid, "weight": fr.weight, "status": fr.status, "impact_pct": round(fr.impact * 100, 1),
                    "recovery": fr.recovery, "recovery_s": fr.recovery_s,
                    "redundancy_lost_pct": round(fr.redundancy_lost * 100, 1), "redundancy_s": fr.redundancy_s})
    out.sort(key=lambda d: (-ORDER[d["status"]], -d["weight"], d["flow"]))
    return out


# ---------------------------------------------------------------- node rolls (EKS)

def _truthy(v) -> bool:
    return str(v).strip().lower() == "true"


def cni_mode(configuration_values) -> tuple[bool, bool] | None:
    """VPC CNI add-on configuration_values (JSON string) -> (prefix delegation, custom networking)."""
    if not isinstance(configuration_values, str) or not configuration_values.strip():
        return None
    try:
        env = (json.loads(configuration_values) or {}).get("env") or {}
    except (json.JSONDecodeError, AttributeError):
        return None
    return _truthy(env.get("ENABLE_PREFIX_DELEGATION")), _truthy(env.get("AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG"))


def label_mode(mode: str | None) -> tuple[bool, bool] | None:
    """'prefix-custom-net' (the cloudbridge.io/pod-ip-mode label) -> (True, True)."""
    if not mode or not isinstance(mode, str):
        return None
    return mode.startswith("prefix"), mode.endswith("custom-net")


def mode_name(m: tuple[bool, bool] | None) -> str | None:
    if m is None:
        return None
    return ("prefix" if m[0] else "secondary-ip") + ("-custom-net" if m[1] else "")


def _lt_mode(state: dict | None) -> tuple[bool, bool] | None:
    """Launch template tags (cloudbridge:pod-ip-mode), top level or in tag_specifications."""
    state = state or {}
    tags = [state.get("tags") or {}] + [ts.get("tags") or {} for ts in state.get("tag_specifications") or []]
    return next((label_mode(t.get("cloudbridge:pod-ip-mode")) for t in tags if t.get("cloudbridge:pod-ip-mode")), None)


def node_roll_check(changes: list[dict], addresses: list[str], rules: dict) -> dict | None:
    """Every change that replaces the EKS nodes, and the prefix-delegation check that goes with it."""
    nr = rules.get("node_roll")
    if not nr:
        return None
    addon = nr.get("addon") or {}
    has_ng = any(resource_type(a) == "aws_eks_node_group" for a in addresses)
    hits, modes = [], {"addon": [None, None], "label": [None, None], "lt": [None, None]}
    for rc, address in zip(changes, addresses):
        ch = rc["change"]
        action = classify(ch["actions"])
        rtype = resource_type(address)
        before, after = ch.get("before") or {}, ch.get("after") or {}
        if rtype == "aws_eks_addon" and action in ("update", "replace"):
            name = after.get("addon_name") or before.get("addon_name")
            attr = addon.get("attribute", "configuration_values")
            if name == addon.get("addon_name", "vpc-cni") and attr in changed_attrs(ch):
                hits.append({"address": address, "action": action, "why": f"{name} {attr} changes"})
                modes["addon"] = [cni_mode(before.get(attr)), cni_mode(after.get(attr))]
            continue
        if rtype not in nr.get("types", []) or action not in nr.get("actions", []):
            continue
        if rtype == "aws_launch_template" and not (has_ng or "node_group" in rc["address"]):
            continue
        hits.append({"address": address, "action": action, "why": f"{rtype} {action}"})
        if rtype == "aws_eks_node_group":
            key = nr.get("mode_label", "cloudbridge.io/pod-ip-mode")
            modes["label"] = [label_mode((before.get("labels") or {}).get(key)),
                              label_mode((after.get("labels") or {}).get(key))]
        else:
            modes["lt"] = [_lt_mode(before), _lt_mode(after)]
    if not hits:
        return None
    # The add-on config is the source of truth; the node label and launch template tag follow it
    src = next((k for k in ("addon", "label", "lt") if modes[k][1] is not None), None)
    b, a = modes[src] if src else (None, None)
    check = None
    pd = nr.get("prefix_delegation") or {}
    if a is not None and a[0] and (b is None or b != a):
        c = pd.get("with_custom_networking" if a[1] else "without_custom_networking")
        if c:
            check = {"id": c["id"], "blocks": bool(c.get("blocks", False)), "message": " ".join(c["message"].split())}
    return {"addresses": hits, "message": " ".join(nr["message"].split()),
            "pod_ip_mode": {"before": mode_name(b), "after": mode_name(a), "source": src},
            "prefix_check": check}


# ---------------------------------------------------------------- hazards

def _cidr_blocks_grow(ch: dict) -> dict | None:
    before = (ch.get("before") or {}).get("cidr_blocks")
    after = (ch.get("after") or {}).get("cidr_blocks")
    if not isinstance(before, list) or not isinstance(after, list):
        return None
    added = [c for c in after if c not in before]
    kept = [c for c in after if c in before]
    return {"added": added, "kept": kept} if added and kept else None


HAZARD_CHECKS = {"cidr_blocks_grow": _cidr_blocks_grow}


def hazard_check(changes: list[dict], addresses: list[str], rules: dict) -> list[dict]:
    out = []
    for rc, address in zip(changes, addresses):
        action = classify(rc["change"]["actions"])
        for h in rules.get("hazards") or []:
            if resource_type(address) != h["match_type"] or action not in h["actions"]:
                continue
            found = HAZARD_CHECKS[h["check"]](rc["change"])
            if found:
                out.append({"id": h["id"], "address": address, "action": action, **found,
                            "blocks": bool(h.get("blocks", True)), "message": " ".join(h["message"].split())})
    return out


def run(plan: dict, model: Model, roots: dict, rules: dict,
        threshold: float | None = None, layer: str | None = None) -> dict:
    threshold = rules.get("threshold", 5) if threshold is None else threshold
    changes = [rc for rc in plan.get("resource_changes", []) if rc.get("mode", "managed") == "managed"]
    addresses = [strip_module(rc["address"]) for rc in changes]
    inferred = layer or infer_layer(addresses, roots)
    notes = []
    if not layer:
        notes.append(f"layer inferred as {inferred}" if inferred
                     else "layer could not be inferred (addresses fit several roots or none); matched across all roots")

    node_roll = node_roll_check(changes, addresses, rules)
    hazards = hazard_check(changes, addresses, rules)
    covered = {h["address"] for h in hazards} | {h["address"] for h in (node_roll or {}).get("addresses", [])}

    persistent, during = set(), set()
    modes_during, modes_after = [], []
    matched, unmatched, ignored = [], [], []
    transitions, convergence = [], []
    conv = rules.get("convergence") or {}
    for rc, address in zip(changes, addresses):
        action = classify(rc["change"]["actions"])
        attrs = changed_attrs(rc["change"]) if action == "update" else {}
        if resource_type(address) in conv.get("types", []) and action in conv.get("actions", []):
            convergence.append({"address": address, "action": action,
                                "window_s": model.recovery_seconds(conv["window"]),
                                "message": " ".join(conv["message"].split())})
        for t in rules.get("transitions") or []:
            if _rule_applies(t, address, action, attrs):
                transitions.append({"id": t["id"], "address": address, "action": action,
                                    "attribute": t["attribute"], "change": list(attrs[t["attribute"]]),
                                    "window_s": model.recovery_seconds(t["window"]),
                                    "blocks": bool(t.get("blocks", True)),
                                    "message": " ".join(t["message"].split())})
        if action in ("create", "read", "no-op"):
            continue
        rule = next((r for r in rules["rules"] if _rule_applies(r, address, action, attrs)), None)
        if rule is None:
            if not any(t["address"] == address for t in transitions) and address not in covered:
                ignored.append({"address": address, "action": action, "attributes": sorted(attrs)})
            continue
        if rule["remove"] == "mapped":
            comps = mapped_components(model, address, inferred)
        else:
            comps = list(rule["remove"])
        if not comps:
            if address in covered:
                continue
            unmatched.append({"address": address, "action": action, "rule": rule["id"]})
            continue
        phase = rule["phase"]
        if phase == "auto":
            phase = "persistent" if action == "delete" else "during-apply"
        (persistent if phase == "persistent" else during).update(comps)
        bgp = rule.get("bgp_failure")
        modes_during.append(bgp)
        if phase == "persistent":
            modes_after.append(bgp)
        matched.append({"address": address, "action": action, "rule": rule["id"], "phase": phase,
                        "removes": comps, "message": " ".join(rule["message"].split()),
                        **({"bgp_failure": bgp} if bgp else {}),
                        **({"attributes": {k: list(v) for k, v in attrs.items()}} if attrs else {})})

    base_removed = model.baseline_removed()
    baseline = model.eval_all(base_removed)
    scenarios = {"during_apply": (base_removed | persistent | during, _expected_mode(modes_during)),
                 "after_apply": (base_removed | persistent, _expected_mode(modes_after))}
    impact, bgp_modes, redundancy = {}, {}, {}
    blocking = []
    for name, (removed, expected) in scenarios.items():
        rows, red = [], []
        results = model.eval_all(removed, expected)
        for fid, fr in results.items():
            b = baseline[fid]
            # The measured rebuild window is for a crash or reboot. A change in a plan stays
            # until the apply ends (during) or until someone changes it back (after).
            fr.redundancy_s = None
            if ORDER[fr.status] <= ORDER[b.status] and fr.impact <= b.impact + 1e-9:
                if fr.redundancy_lost > b.redundancy_lost + 1e-9:
                    red.append({"flow": fid, "weight": fr.weight,
                                "redundancy_lost_pct": round(fr.redundancy_lost * 100, 1),
                                "redundancy_s": fr.redundancy_s})
                continue
            d = fr.to_dict()
            d["flow_name"] = model.flows[fid]["name"]
            d["baseline_status"] = b.status
            d["severity"] = model.severity(fr)
            d["blocks"] = fr.weight >= threshold and fr.status in ("degraded", "broken")
            rows.append(d)
            if d["blocks"]:
                blocking.append((name, fid))
        rows.sort(key=lambda d: (-ORDER[d["status"]], -d["weight"], d["flow"]))
        red.sort(key=lambda d: (-d["weight"], d["flow"]))
        impact[name] = rows
        redundancy[name] = red
        # Report both BGP failure modes, labelled, when they give different answers
        per = {fm: _mode_summary(model, baseline, model.eval_all(removed, fm)) for fm in ("clean", "silent")}
        if per["clean"] != per["silent"]:
            bgp_modes[name] = {"expected": expected,
                               "modes": {fm: {"name": model.failure_modes[fm]["name"],
                                              "examples": model.failure_modes[fm]["examples"],
                                              "flows": per[fm]} for fm in per}}
    # An outage that only exists while the apply runs is restored by the same apply
    after = {d["flow"] for d in impact["after_apply"]}
    for d in impact["during_apply"]:
        if d["flow"] not in after and d["recovery"] in ("manual", "provider"):
            d["recovery"] = "end of apply"
    blocks = [{"scenario": s, "flow": f} for s, f in blocking]
    blocks += [{"scenario": "transition", "flow": None, "transition": t["id"]} for t in transitions if t["blocks"]]
    pc = (node_roll or {}).get("prefix_check")
    if pc and pc["blocks"]:
        blocks.append({"scenario": "node-roll", "flow": None, "hazard": pc["id"]})
    blocks += [{"scenario": "hazard", "flow": None, "hazard": h["id"], "address": h["address"]}
               for h in hazards if h["blocks"]]
    verdict = "block" if blocks else "pass"
    return {
        "tool": "mindbridge precheck",
        "threshold": threshold,
        "layer": inferred,
        "notes": notes,
        "changes": matched,
        "unmapped_changes": unmatched,
        "changes_without_rule": ignored,
        "removed": {"persistent": sorted(persistent), "during_apply": sorted(during)},
        "impact": impact,
        "bgp_failure_modes": bgp_modes,
        "redundancy": redundancy,
        "transitions": transitions,
        "convergence": convergence,
        "node_roll": node_roll,
        "hazards": hazards,
        "verdict": verdict,
        "blocking": blocks,
        "exit_code": 2 if blocks else 0,
    }


def load_plan(path: Path | str) -> dict:
    with open(path) as fh:
        return json.load(fh)


def to_text(res: dict) -> str:
    L = [f"MindBridge precheck  layer={res['layer'] or '?'}  threshold=weight {res['threshold']}"]
    L += [f"  note: {n}" for n in res["notes"]]
    L.append("")
    if not res["changes"] and not res.get("node_roll") and not res.get("hazards"):
        L.append("No change in this plan maps to a modelled component.")
    for c in res["changes"]:
        L.append(f"- {c['action']:8} {c['address']}  [{c['rule']}, {c['phase']}]")
        L.append(f"    removes: {', '.join(c['removes'])}")
        L.append(f"    {c['message']}")
    for u in res["unmapped_changes"]:
        L.append(f"- {u['action']:8} {u['address']}  (not in the model: check by hand)")
    if res["changes_without_rule"]:
        L.append("")
        L.append("Updates with no rule (treated as safe): " +
                 ", ".join(f"{c['address']} {c['attributes']}" for c in res["changes_without_rule"]))
    for t in res.get("transitions", []):
        L.append("")
        flag = "  BLOCK" if t["blocks"] else ""
        L.append(f"Transition risk: {t['address']} {t['attribute']} {t['change'][0]} -> {t['change'][1]}"
                 f" (~{_dur(t['window_s'])} window){flag}")
        L.append(f"    {t['message']}")
    nr = res.get("node_roll")
    if nr:
        if L[-1]:
            L.append("")
        L.append(f"Node roll: {nr['message'].removeprefix('Node roll: ')}")
        for h in nr["addresses"]:
            L.append(f"  - {h['action']:8} {h['address']}")
        m = nr["pod_ip_mode"]
        if m["after"]:
            L.append(f"  pod-IP mode: {m['before'] or '?'} -> {m['after']} (from the {m['source']})")
        pc = nr.get("prefix_check")
        if pc:
            L.append(f"  {'BLOCK' if pc['blocks'] else 'WARNING'} [{pc['id']}]: {pc['message']}")
    for h in res.get("hazards", []):
        if L[-1]:
            L.append("")
        L.append(f"Hazard [{h['id']}]: {h['action']} {h['address']}{'  BLOCK' if h['blocks'] else ''}")
        if "added" in h:
            L.append(f"    cidr_blocks keeps {', '.join(h['kept'])} and adds {', '.join(h['added'])}")
        L.append(f"    {h['message']}")
    if res.get("convergence"):
        L.append("")
        L.append("Route-change convergence window (not a block):")
        for c in res["convergence"]:
            L.append(f"  - {c['action']:8} {c['address']}: ~{_dur(c['window_s'])}")
        L.append(f"    {res['convergence'][0]['message']}")
    after_flows = {d["flow"] for d in res["impact"]["after_apply"]}
    for scen, title in (("during_apply", "While the apply runs"), ("after_apply", "After the apply")):
        L.append("")
        L.append(f"{title}:")
        rows = res["impact"][scen]
        red_rows = res.get("redundancy", {}).get(scen, [])
        if not rows:
            L.append("  no flow loses traffic" if red_rows else "  no flow gets worse")
        for r in rows:
            pct = "" if r["status"] == "broken" else f" {r['impact_pct']:g}%"
            rec = r["recovery"] + (f" ~{r['recovery_s']:g} s" if r["recovery_s"] else "")
            if r.get("redundancy_s"):
                rec += f", then reduced redundancy ~{_dur(r['redundancy_s'])}"
            flag = "  BLOCK" if r["blocks"] else ""
            L.append(f"  {r['flow']:18} w={r['weight']:<3g} {r['status']}{pct}, recovery {rec}{flag}")
            for h in r["hops_hit"]:
                if h["impact_pct"] > 0:
                    L.append(f"      hop {h['hop']}: {h['impact_pct']:g}% lost ({', '.join(h['lost'])})")
        after_red = {d["flow"] for d in res.get("redundancy", {}).get("after_apply", [])} | after_flows
        for d in red_rows:
            if d["redundancy_s"]:
                win = f" for ~{_dur(d['redundancy_s'])}"
            elif scen == "during_apply" and d["flow"] not in after_red:
                win = " until the apply ends"
            else:
                win = " until fixed"
            L.append(f"  {d['flow']:18} w={d['weight']:<3g} no packet loss expected; redundancy reduced "
                     f"{d['redundancy_lost_pct']:g}%{win}")
        bm = res.get("bgp_failure_modes", {}).get(scen)
        if bm:
            L.append("  BGP failure modes (both shown; the verdict uses the expected one):")
            for fm, m in bm["modes"].items():
                tag = "expected" if fm == bm["expected"] else "if instead"
                hit = [f for f in m["flows"] if f["status"] != "ok"]
                if hit:
                    w = hit[0]
                    rec = f"~{w['recovery_s']:g} s" if w["recovery_s"] is not None else w["recovery"]
                    what = "; ".join(f"{f['flow']} {f['status']} {f['impact_pct']:g}%" for f in hit[:3])
                    what += f", recovery {rec}"
                else:
                    what = "no flow loses packets (measured 0 of 16 flows, ~0 s)" if fm == "clean" else "no flow loses packets"
                L.append(f"    [{tag}] {m['name']}: {what}")
    L.append("")
    L.append(f"Verdict: {res['verdict'].upper()} (exit {res['exit_code']})")
    return "\n".join(L)


def _dur(s) -> str:
    if s is None:
        return "?"
    return f"{s:g} s" if s < 120 else f"{s / 60:.0f} min"
