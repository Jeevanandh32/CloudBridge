"""Optional AI explainer on top of the deterministic what-if report.

Sends only the report rows, flows, constraints, fix catalogue and the component list, plus
predict-mode alerts (with their what-if impact) when an alert set exists.
No account IDs, no secrets, no tfvars, no Terraform source. The model is told to quote
only numbers that appear in the report, and the reply is checked for numbers that don't.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

DEFAULT_MODEL = "claude-opus-5-5"
# Models that accept the server-side refusal fallback parameter
FALLBACK_MODELS = {"claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"}
ADAPTIVE_MODELS = FALLBACK_MODELS | {"claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-5",
                                     "claude-sonnet-4-6", "claude-haiku-5-5", "claude-fable-5"}

SYSTEM = """You explain a network resilience report to a network engineer.

The report was produced by a deterministic N-1 analysis of a two-cloud lab (AWS + Azure):
each component was removed in turn and every business flow re-evaluated. It is the only
source of truth.

Rules:
- Rank the risks by business impact, using the report's severity scores and flow weights.
- Explain each risk in plain language: what fails, which traffic stops or shrinks, and why
  recovery is automatic or manual.
- Propose fixes only from the fixes listed for that component. Respect the constraints: never
  recommend a fix the report marks as blocked, but say why it is blocked.
- Quote only numbers that appear in the report JSON (severity, weights, percentages, seconds,
  dollars, quota counts). Do not estimate, round into new values, or add numbers of your own.
- Components with status "planned" are not yet in code; say so when you mention them.
- Rows with "failure_modes" were scored for a BGP clean withdrawal and a silent failure; name
  both when you discuss them. "redundancy_s" is how long a component stays degraded after
  users have recovered; "transition_risk" means changing that setting on live traffic is
  disruptive in itself.
- Keep it under about 700 words (900 with alerts). Markdown headings and short lists are fine."""

SYSTEM_ALERTS = """

The report also has an "alerts" section from predict mode. Deterministic detectors computed
each alert from live samples (trend to a threshold with an ETA, deviation from a baseline, flap
counts, countdowns, quota headroom), and each alert's "impact" comes from the same what-if
model: what breaks if that component fails, and how recovery works.

For the alerts:
- Start with a short "Warnings now" section, most urgent first (severity, then ETA).
- For each alert, say what the signal shows, how long is left (quote eta_s / eta exactly as
  given), and what breaks if it gets there (from its impact). Correlate alerts that point at
  the same component or the same path, e.g. RTT and loss on one destination, or a tunnel flap
  seen by both AWS and Azure; say when they are likely one problem.
- An alert's impact with "candidates" means the signal cannot tell which component it is; say so.
- Quote only numbers that appear in the alerts JSON. Do not make up an ETA, a probability or a
  cause the data doesn't show."""

ALERT_KEYS = ("id", "signal", "component", "detector", "severity", "summary", "eta_s", "eta", "deviation",
              "metrics", "at")

SAFE_ROW_KEYS = ("rank", "component", "name", "cloud", "layer", "planned_layer", "status", "kind", "section",
                 "severity", "band", "worst_status", "recovery", "recovery_s", "redundancy_s", "summary",
                 "failure_mode", "failure_modes", "transition_risk", "flows", "fixes")


def alerts_payload(alerts_doc: dict) -> list[dict]:
    """Alert fields, evidence values and impact flows only: no collector messages or raw details."""
    out = []
    for a in alerts_doc.get("alerts", []):
        imp = a.get("impact") or {}
        out.append({
            **{k: a.get(k) for k in ALERT_KEYS},
            "evidence": [{"ts": e["ts"], "value": e["value"], "unit": e["unit"]} for e in a.get("evidence", [])],
            "impact": {
                "component": imp.get("component"),
                "answer": imp.get("answer"),
                "note": imp.get("note"),
                "recovery": imp.get("recovery"),
                "recovery_s": imp.get("recovery_s"),
                "flows": [{k: f.get(k) for k in ("flow", "status", "impact_pct", "recovery", "recovery_s", "severity")}
                          for f in imp.get("flows", [])],
                **({"candidates": [c["component"] for c in imp["candidates"]]} if imp.get("candidates") else {}),
            },
        })
    return out


def build_payload(report: dict, model, alerts: dict | None = None) -> dict:
    """Only what the explainer needs. Terraform addresses, facts' sources and IDs are left out."""
    rows = [{k: r.get(k) for k in SAFE_ROW_KEYS} for r in report["rows"] if r["flows"] or r.get("transition_risk")]
    for r in rows:
        r["flows"] = [{k: f.get(k) for k in ("flow", "status", "impact_pct", "recovery", "recovery_s",
                                              "redundancy_lost_pct", "redundancy_s", "severity", "note")}
                      for f in r["flows"]]
    components = [{"id": c["id"], "name": c["name"], "cloud": c["cloud"], "layer": c["layer"],
                   "planned_layer": c.get("planned_layer"), "status": c["status"], "kind": c["kind"]}
                  for c in model.components.values()]
    payload = {
        "method": report["method"],
        "scoring": report["scoring"],
        "flows": report["flows"],
        "constraints": report["constraints"],
        "recovery_times": {k: {"value": v["value"], **({"range": v["range"]} if "range" in v else {}),
                               **({"estimate": True} if v.get("estimate") else {})}
                           for k, v in report["recovery_times"].items()},
        "rows": rows,
        "components": components,
    }
    if alerts is not None:
        payload["alerts_generated"] = alerts.get("generated")
        payload["alerts"] = alerts_payload(alerts)
    return payload


_SECRETISH = [
    re.compile(r"\b\d{12}\b"),                              # AWS account id
    re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I),  # subscription / tenant
    re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+"),                 # email
    re.compile(r"tfstate-\d"),
]


def assert_clean(text: str) -> None:
    for rx in _SECRETISH:
        m = rx.search(text)
        if m:
            raise ValueError(f"payload looks like it contains an identifier ({rx.pattern}); refusing to send")


_NUM = re.compile(r"(?<![\w.])\d+(?:\.\d+)?")


def unknown_numbers(answer: str, payload_text: str) -> list[str]:
    """Numbers in the answer that are not in the payload (component ids and CIDRs included)."""
    allowed = set(_NUM.findall(payload_text))
    allowed |= {str(float(n)).rstrip("0").rstrip(".") for n in list(allowed)}
    found = []
    for n in _NUM.findall(answer):
        norm = str(float(n)).rstrip("0").rstrip(".") if "." in n else n
        if n not in allowed and norm not in allowed and n not in found:
            found.append(n)
    return found


def explain(report: dict, model, out_path: Path | None = None, alerts: dict | None = None) -> int:
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("explain: ANTHROPIC_API_KEY is not set; skipping the AI explanation. "
              "The deterministic report is complete without it.")
        return 0
    try:
        import anthropic
    except ImportError:
        print("explain: the anthropic package is not installed (pip install -r requirements.txt); skipping.")
        return 0

    payload = build_payload(report, model, alerts)
    payload_text = json.dumps(payload, indent=1)
    assert_clean(payload_text)

    model_id = os.environ.get("MINDBRIDGE_MODEL", DEFAULT_MODEL)
    client = anthropic.Anthropic()
    params = dict(
        model=model_id,
        max_tokens=16000,
        system=SYSTEM + (SYSTEM_ALERTS if alerts is not None else ""),
        messages=[{"role": "user", "content":
                   "Here is the deterministic what-if report as JSON" + (" with the predict-mode alerts" if alerts
                   is not None else "") + ". Rank, explain and propose fixes as instructed."
                   "\n\n<report>\n" + payload_text + "\n</report>"}],
    )
    if model_id in ADAPTIVE_MODELS:
        params["thinking"] = {"type": "adaptive"}
        params["output_config"] = {"effort": "high"}

    try:
        if model_id in FALLBACK_MODELS:
            resp = client.beta.messages.create(betas=["server-side-fallback-2026-07-01"], fallbacks="default", **params)
        else:
            resp = client.messages.create(**params)
    except anthropic.AuthenticationError:
        print("explain: the API key was rejected (401).")
        return 1
    except anthropic.RateLimitError:
        print("explain: rate limited (429); try again later.")
        return 1
    except anthropic.APIStatusError as e:
        print(f"explain: API error {e.status_code}: {e.message}")
        return 1
    except anthropic.APIConnectionError:
        print("explain: could not reach the API.")
        return 1

    if resp.stop_reason == "refusal":
        print("explain: the model declined this request.")
        return 1
    text = "".join(b.text for b in resp.content if b.type == "text").strip()
    if resp.stop_reason == "max_tokens":
        text += "\n\n_(cut off at the token limit)_"

    stray = unknown_numbers(text, payload_text)
    src = "docs/mindbridge/whatif-report.json" + (" and the predict alerts" if alerts is not None else "")
    footer = ["", "---", f"Generated by `python -m mindbridge explain` from the deterministic report "
              f"({src}). Numbers come from that report."]
    if stray:
        footer.append("**Check:** these numbers in the explanation are not in the report: " + ", ".join(stray))
    out = text + "\n" + "\n".join(footer) + "\n"
    print(out)
    if out_path:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(out)
        print(f"wrote {out_path}")
    return 0
