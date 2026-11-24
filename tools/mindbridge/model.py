"""Topology model and the deterministic flow evaluator.

Everything that decides whether a flow is OK, degraded or broken lives here. No AI involved.
"""
from __future__ import annotations

import copy
from dataclasses import dataclass, field
from pathlib import Path

import yaml

PKG_DIR = Path(__file__).resolve().parent
REPO_ROOT = PKG_DIR.parents[1]
DESIGN_PATH = PKG_DIR / "design.yaml"

# Worse recovery wins when several hops are hit
RECOVERY_ORDER = {"none": 0, "auto": 1, "provider": 2, "manual": 3}


@dataclass
class HopResult:
    hop: str
    impact: float
    recovery: str  # none | auto | provider | manual
    recovery_s: float | None
    lost: list[str]
    note: str = ""
    # share of a failover hop's members lost while the survivors carry the traffic, and how long
    # the hop stays that way after traffic has recovered (None = until someone fixes it)
    redundancy_lost: float = 0.0
    redundancy_s: float | None = None
    failure_mode: str | None = None   # BGP failure mode used for this hop (clean | silent)


@dataclass
class FlowResult:
    flow: str
    weight: float
    status: str  # ok | degraded | broken
    impact: float
    recovery: str
    recovery_s: float | None
    hops: list[HopResult] = field(default_factory=list)
    note: str = ""
    redundancy_lost: float = 0.0
    redundancy_s: float | None = None
    failure_mode: str | None = None

    def to_dict(self) -> dict:
        return {
            "flow": self.flow,
            "weight": self.weight,
            "status": self.status,
            "impact_pct": round(self.impact * 100, 1),
            "recovery": self.recovery,
            "recovery_s": self.recovery_s,
            "redundancy_lost_pct": round(self.redundancy_lost * 100, 1),
            "redundancy_s": self.redundancy_s,
            "failure_mode": self.failure_mode,
            "note": self.note,
            "hops_hit": [
                {
                    "hop": h.hop,
                    "impact_pct": round(h.impact * 100, 1),
                    "recovery": h.recovery,
                    "recovery_s": h.recovery_s,
                    "lost": h.lost,
                    **({"redundancy_lost_pct": round(h.redundancy_lost * 100, 1),
                        "redundancy_s": h.redundancy_s} if h.redundancy_lost > 0 else {}),
                    **({"failure_mode": h.failure_mode} if h.failure_mode else {}),
                    **({"note": h.note} if h.note else {}),
                }
                for h in self.hops
                if h.impact > 0 or h.redundancy_lost > 0
            ],
        }

    def same_as(self, other: "FlowResult") -> bool:
        """No user-visible or redundancy difference (used to skip unaffected flows)."""
        return (self.status == other.status and abs(self.impact - other.impact) < 1e-9
                and self.note == other.note and abs(self.redundancy_lost - other.redundancy_lost) < 1e-9)


class Model:
    def __init__(self, data: dict):
        self.data = data
        self.components: dict[str, dict] = {c["id"]: c for c in data["components"]}
        self.hops: dict[str, dict] = data["hops"]
        self.flows: dict[str, dict] = {f["id"]: f for f in data["flows"]}
        self.recovery_times: dict[str, dict] = data["recovery_times"]
        self.scoring: dict = data["scoring"]
        self.fixes: dict = data.get("fixes", {})
        self.constraints: dict = data.get("constraints", {})
        self.failure_modes: dict = data.get("failure_modes", {})
        for c in self.components.values():
            c.setdefault("present", True)
            c.setdefault("requires", [])
            c.setdefault("tf", [])
            c["status"] = "planned" if c["layer"] == "planned" else "built"
        self._validate()

    @classmethod
    def load(cls, path: Path | str = DESIGN_PATH) -> "Model":
        with open(path) as fh:
            return cls(yaml.safe_load(fh))

    def copy(self) -> "Model":
        return Model(copy.deepcopy(self.data_with_state()))

    def data_with_state(self) -> dict:
        d = copy.deepcopy(self.data)
        d["components"] = [copy.deepcopy(c) for c in self.components.values()]
        d["hops"] = copy.deepcopy(self.hops)
        return d

    def _validate(self) -> None:
        for hid, hop in self.hops.items():
            if hop["mode"] not in ("failover", "pinned", "single"):
                raise ValueError(f"hop {hid}: unknown mode {hop['mode']}")
            for m in hop["members"]:
                if m not in self.components:
                    raise ValueError(f"hop {hid}: unknown member {m}")
            if hop["mode"] == "failover" and "recovery" in hop and hop["recovery"] not in self.recovery_times:
                raise ValueError(f"hop {hid}: unknown recovery {hop['recovery']}")
            for fm, spec in (hop.get("failure_modes") or {}).items():
                if fm not in self.failure_modes:
                    raise ValueError(f"hop {hid}: unknown failure mode {fm}")
                if spec.get("recovery") not in self.recovery_times:
                    raise ValueError(f"hop {hid}: failure mode {fm}: unknown recovery {spec.get('recovery')}")
        for c in self.components.values():
            for r in c["requires"]:
                if r not in self.components:
                    raise ValueError(f"component {c['id']}: unknown requires {r}")
            for fm in c.get("failure_modes") or []:
                if fm not in self.failure_modes:
                    raise ValueError(f"component {c['id']}: unknown failure mode {fm}")
            rw = c.get("redundancy_window")
            if rw and rw not in self.recovery_times:
                raise ValueError(f"component {c['id']}: unknown redundancy_window {rw}")
        for f in self.flows.values():
            if "failover" in f:
                fo = f["failover"]
                for k in ("primary", "standby"):
                    if fo[k] not in self.flows:
                        raise ValueError(f"flow {f['id']}: unknown {k} {fo[k]}")
                if fo["switch"] not in self.hops:
                    raise ValueError(f"flow {f['id']}: unknown switch hop")
            else:
                for h in f["hops"]:
                    if h not in self.hops:
                        raise ValueError(f"flow {f['id']}: unknown hop {h}")

    # ---------------- helpers ----------------

    def baseline_removed(self) -> set[str]:
        """Components the code says are absent (e.g. a Test 4 toggle set to break)."""
        return {cid for cid, c in self.components.items() if not c["present"]}

    def recovery_seconds(self, key: str | None) -> float | None:
        if not key:
            return None
        return float(self.recovery_times[key]["value"])

    def root_causes(self, cid: str, removed: set[str]) -> list[str]:
        """Removed components that make `cid` dead (itself or anything it requires)."""
        out = []
        if cid in removed:
            out.append(cid)
        for r in self.components[cid]["requires"]:
            out.extend(self.root_causes(r, removed))
        return out

    def alive(self, cid: str, removed: set[str]) -> bool:
        return not self.root_causes(cid, removed)

    def _worst_recovery(self, causes: list[str]) -> str:
        worst = "auto"
        for c in causes:
            r = self.components[c]["recovery_if_lost"]
            if RECOVERY_ORDER[r] > RECOVERY_ORDER[worst]:
                worst = r
        return worst

    # ---------------- evaluation ----------------

    def _redundancy_window(self, causes: list[str]) -> float | None:
        """Longest measured rebuild time of the lost components (None if any has none)."""
        vals = []
        for c in causes:
            key = self.components[c].get("redundancy_window")
            if not key:
                return None
            vals.append(self.recovery_seconds(key))
        return max(vals) if vals else None

    def eval_hop(self, hid: str, removed: set[str], fmode: str | None = None, path: str | None = None) -> HopResult:
        """fmode: BGP failure mode (clean | silent) for hops that model it; None = the hop's default.
        path: the flow's path kind (e.g. vpn-vpc), for hops whose loss depends on it."""
        hop = self.hops[hid]
        members = hop["members"]
        dead = [m for m in members if not self.alive(m, removed)]
        if not dead:
            return HopResult(hid, 0.0, "none", None, [])
        causes = sorted({c for m in dead for c in self.root_causes(m, removed)})
        mode = hop["mode"]
        if mode == "failover" and len(dead) < len(members):
            share = len(dead) / len(members)
            modes = hop.get("failure_modes") or {}
            used = None
            rec_key, factor = hop.get("recovery"), 1.0
            if modes:
                used = fmode if fmode in modes else hop.get("default_failure_mode", next(iter(modes)))
                rec_key = modes[used]["recovery"]
                factor = float(modes[used].get("impact_factor", 1.0))
            note = f"{len(members) - len(dead)} of {len(members)} members carry the traffic"
            if used:
                note += f" ({self.failure_modes[used]['name']})"
            return HopResult(hid, share * factor, "auto" if factor > 0 else "none",
                             self.recovery_seconds(rec_key), causes, note,
                             redundancy_lost=share, redundancy_s=self._redundancy_window(causes),
                             failure_mode=used)
        if mode == "pinned":
            return HopResult(hid, len(dead) / len(members), self._worst_recovery(causes), None, causes,
                             "traffic pinned to the lost member has no automatic failover")
        # single, or failover with nothing left
        if mode == "single":
            impact = float(hop.get("loss_impact", 1.0))
            by_path = hop.get("loss_impact_by_path") or {}
            note = hop.get("loss_note", "")
            if path in by_path:
                impact = float(by_path[path])
                note = (hop.get("path_notes") or {}).get(path, note)
            if impact <= 0:
                return HopResult(hid, 0.0, "none", None, causes, note)
        else:
            impact = 1.0
            note = hop.get("loss_note", "")
        return HopResult(hid, impact, self._worst_recovery(causes), None, causes, note)

    def eval_flow(self, fid: str, removed: set[str], fmode: str | None = None) -> FlowResult:
        flow = self.flows[fid]
        if "failover" in flow:
            return self._eval_failover_flow(flow, removed, fmode)
        results = [self.eval_hop(h, removed, fmode, flow.get("path")) for h in flow["hops"]]
        surviving = 1.0
        recovery, rec_s = "none", None
        red_lost, red_s, used = 0.0, None, None
        for r in results:
            if r.redundancy_lost > red_lost:
                red_lost, red_s = r.redundancy_lost, r.redundancy_s
            used = used or r.failure_mode
            if r.impact <= 0:
                continue
            surviving *= 1.0 - r.impact
            if RECOVERY_ORDER[r.recovery] > RECOVERY_ORDER[recovery]:
                recovery = r.recovery
            if r.recovery == "auto" and r.recovery_s is not None:
                rec_s = max(rec_s or 0.0, r.recovery_s)
        impact = round(1.0 - surviving, 6)
        if recovery != "auto":
            rec_s = None
        return FlowResult(fid, flow["weight"], _status(impact), impact, recovery, rec_s, results,
                          redundancy_lost=red_lost, redundancy_s=red_s, failure_mode=used)

    def _eval_failover_flow(self, flow: dict, removed: set[str], fmode: str | None = None) -> FlowResult:
        fo = flow["failover"]
        prim = self.eval_flow(fo["primary"], removed, fmode)
        stby = self.eval_flow(fo["standby"], removed, fmode)
        if prim.status != "broken":
            note = ""
            if stby.status == "broken":
                note = f"failover path {fo['standby']} is broken: no fallback if {fo['primary']} fails"
            return FlowResult(flow["id"], flow["weight"], prim.status, prim.impact, prim.recovery,
                              prim.recovery_s, prim.hops, note, prim.redundancy_lost, prim.redundancy_s,
                              prim.failure_mode)
        switch = self.eval_hop(fo["switch"], removed, fmode)
        if stby.status == "ok" and switch.impact < 1.0:
            rec_s = self.recovery_seconds(self.hops[fo["switch"]].get("recovery"))
            return FlowResult(flow["id"], flow["weight"], "degraded", 1.0, "auto", rec_s,
                              prim.hops + [switch],
                              f"{fo['primary']} broken; DNS health checks move users to {fo['standby']}")
        return FlowResult(flow["id"], flow["weight"], "broken", 1.0, prim.recovery, None,
                          prim.hops + stby.hops + [switch],
                          f"{fo['primary']} broken and {fo['standby']} cannot take over")

    def eval_all(self, removed: set[str], fmode: str | None = None) -> dict[str, FlowResult]:
        return {fid: self.eval_flow(fid, removed, fmode) for fid in self.flows}

    def modes_for(self, cids) -> list[str | None]:
        """BGP failure modes to evaluate when these components are lost ([None] = not modelled)."""
        modes: list[str] = []
        for cid in cids:
            for fm in self.components[cid].get("failure_modes") or []:
                if fm not in modes:
                    modes.append(fm)
        return modes or [None]

    # ---------------- scoring ----------------

    def penalty(self, recovery: str, recovery_s: float | None) -> float:
        p = self.scoring["recovery_penalty"]
        if recovery == "manual":
            return float(p["manual"])
        if recovery == "provider":
            return float(p["provider"])
        if recovery == "auto":
            return min(float(p["auto_cap"]), float(p["auto_base"]) + (recovery_s or 0.0) / float(p["auto_per_s"]))
        return 0.0

    def redundancy_penalty(self, fr: FlowResult) -> float:
        """Extra severity for the time a failover hop runs on fewer members after traffic has
        recovered (the reduced-redundancy window): weight x share lost x min(cap, s / per_s)."""
        rr = self.scoring.get("reduced_redundancy")
        if not rr or fr.redundancy_lost <= 0 or fr.redundancy_s is None:
            return 0.0
        return fr.weight * fr.redundancy_lost * min(float(rr["cap"]), fr.redundancy_s / float(rr["per_s"]))

    def severity(self, fr: FlowResult) -> float:
        base = 0.0 if fr.status == "ok" else fr.weight * fr.impact * self.penalty(fr.recovery, fr.recovery_s)
        return round(base + self.redundancy_penalty(fr), 2)

    def band(self, score: float) -> str:
        b = self.scoring["bands"]
        if score >= b["high"]:
            return "high"
        if score >= b["medium"]:
            return "medium"
        if score > 0:
            return "low"
        return "none"

    # ---------------- fixes ----------------

    def constraint_usage(self, facts: dict | None = None) -> dict:
        """Quota headroom and the extra $/hr the budget allows."""
        facts = facts or {}
        out = {}
        for key in ("azure_public_ips", "azure_bseries_vcpu"):
            c = self.constraints.get(key)
            if not c:
                continue
            used = facts.get(c["used_from_fact"], {}).get("value")
            out[key] = {"limit": c["limit"], "used": used,
                        "free": (c["limit"] - used) if isinstance(used, (int, float)) else None}
        b = self.constraints.get("budget")
        if b:
            out["budget"] = {
                "total_usd": b["total_usd"],
                "planned_spend_usd": b["planned_spend_usd"],
                "max_extra_usd_per_hr": round((b["total_usd"] - b["planned_spend_usd"]) / b["remaining_session_hours"], 3),
            }
        return out

    def fixes_for(self, risk: str, usage: dict) -> list[dict]:
        out = []
        for fx in self.fixes.get(risk, []):
            blocked = []
            for k, need in (fx.get("needs") or {}).items():
                free = usage.get(k, {}).get("free")
                if free is None:
                    blocked.append(f"{k}: usage unknown")
                elif need > free:
                    blocked.append(f"{k}: needs {need}, {free} free of {usage[k]['limit']}")
            max_extra = usage.get("budget", {}).get("max_extra_usd_per_hr")
            if max_extra is not None and fx["usd_per_hr"] > max_extra:
                blocked.append(f"budget: ${fx['usd_per_hr']}/hr > ${max_extra}/hr headroom")
            out.append({"mitigation": fx["mitigation"], "usd_per_hr": fx["usd_per_hr"],
                        "blocked": bool(blocked), "blocked_by": blocked})
        return out


def _status(impact: float) -> str:
    if impact <= 0:
        return "ok"
    if impact >= 0.999:
        return "broken"
    return "degraded"


def parse_tf_entry(entry: str, default_layer: str) -> tuple[str, str]:
    """'aws/hub:aws_x.y' -> ('aws/hub', 'aws_x.y'); 'aws_x.y' -> (default_layer, 'aws_x.y')."""
    head, sep, tail = entry.partition(":")
    if sep and "/" in head and "." not in head:
        return head, tail
    return default_layer, entry
