"""python -m mindbridge {whatif,precheck,explain,facts,watch,predict,replay}  (run from tools/)"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .model import REPO_ROOT


def _out_dir(args) -> Path:
    return Path(args.out_dir) if args.out_dir else Path(args.repo) / "docs" / "mindbridge"


def cmd_whatif(args) -> int:
    from .builder import build
    from .whatif import build_report, write

    model, facts, log, problems, _ = build(Path(args.repo))
    report = build_report(model, facts, log, problems)
    md, js = write(report, _out_dir(args))
    infra = [r for r in report["rows"] if r["section"] == "infrastructure" and r["flows"]][: args.top]
    print("Infrastructure single points of failure, worst first:")
    print(f"{'#':>2}  {'component':28} {'severity':>9}  {'band':6} {'worst':9} recovery")
    for i, r in enumerate(infra, 1):
        rec = f"auto ~{r['recovery_s']:g} s" if r["recovery"] == "auto" else r["recovery"]
        if r.get("redundancy_s"):
            rec += f", reduced redundancy ~{r['redundancy_s'] / 60:.0f} min"
        mode = f"  [{r['failure_mode']}]" if r.get("failure_mode") else ""
        print(f"{i:>2}  {r['component']:28} {r['severity']:>9g}  {r['band']:6} {r['worst_status']:9} {rec}{mode}")
    unresolved = [u["fact"] for u in report["unresolved"]]
    if unresolved:
        print(f"\nnot resolved from Terraform: {', '.join(unresolved)}")
    if problems:
        print(f"\nmodel addresses not found in code: {len(problems)}")
    print(f"\nwrote {md}\nwrote {js}")
    return 0


def cmd_precheck(args) -> int:
    from .builder import build
    from .precheck import load_plan, load_rules, run, to_text

    model, _, _, _, roots = build(Path(args.repo))
    res = run(load_plan(args.plan), model, roots, load_rules(), threshold=args.threshold, layer=args.layer)
    print(json.dumps(res, indent=2) if args.json else to_text(res))
    return res["exit_code"]


def cmd_explain(args) -> int:
    from .builder import build
    from .explain import explain

    report_path = Path(args.report) if args.report else _out_dir(args) / "whatif-report.json"
    if not report_path.exists():
        print(f"explain: {report_path} not found; run `python -m mindbridge whatif` first.")
        return 1
    report = json.loads(report_path.read_text())
    alerts = None
    alerts_path = Path(args.alerts) if args.alerts else _latest_alerts(_out_dir(args))
    if alerts_path and not args.no_alerts:
        alerts = json.loads(alerts_path.read_text())
        print(f"explain: including {len(alerts.get('alerts', []))} alerts from {alerts_path.name}")
    model, *_ = build(Path(args.repo))
    return explain(report, model, _out_dir(args) / "explanation.md", alerts=alerts)


def _latest_alerts(out_dir: Path) -> Path | None:
    files = sorted(out_dir.glob("alerts-*.json"))
    return files[-1] if files else None


def _model(args):
    """The model with the Terraform facts applied; falls back to design.yaml alone."""
    from .builder import build
    from .model import Model

    try:
        return build(Path(args.repo))[0]
    except Exception as e:  # noqa: BLE001 - an unparsable root must not stop predict mode
        print(f"(builder failed: {type(e).__name__}; using design.yaml without Terraform facts)")
        return Model.load()


def _print_alerts(alerts: list[dict], header: str = "alerts") -> None:
    if not alerts:
        print(f"{header}: none")
        return
    print(f"{header}: {len(alerts)}")
    for a in alerts:
        eta = f" ETA {a['eta']}" if a.get("eta") else ""
        print(f"  {a['severity']:8} {a['id']}{eta}: {a['summary']}")
        print(f"           impact: {a['impact']['answer']}")


def cmd_watch(args) -> int:
    import time

    from .collect import REGISTRY, run_collector
    from .predict import SignalConfig, attach_impact, evaluate, Impact
    from .store import Store

    model = _model(args)
    cfg = SignalConfig.from_model(model)
    store = Store(args.db)
    names = [n for n in REGISTRY if not args.only or n in args.only.split(",")]
    print(f"watch: store {store.path}; collectors: {', '.join(names)}")
    last_run: dict[str, float] = {}
    seen: set[str] = set()
    impact = Impact(model, cfg)
    try:
        while True:
            now = time.time()
            for n in names:
                c = cfg.collectors.get(n, {})
                if not args.once and now - last_run.get(n, 0) < float(c.get("interval", args.interval)):
                    continue
                last_run[n] = now
                res = run_collector(REGISTRY[n], cfg.targets, float(c.get("timeout", 60)))
                store.add_samples(res.samples, n)
                store.add_run(n, res.status, res.message, len(res.samples), res.duration_s)
                msg = f" ({res.message})" if res.message else ""
                print(f"  {n:20} {res.status:11} {len(res.samples):3} samples {res.duration_s:6.1f} s{msg}")
                if args.verbose:
                    for s in res.samples:
                        print(f"      {s.signal:28} {s.component:28} {s.value:g} {s.unit} {s.detail}")
            since = time.time() - max(cfg.max_lookback_s(), 1800)
            alerts = attach_impact(evaluate(store.samples(since=since), cfg, now=time.time()), impact)
            new = [a for a in alerts if a["id"] not in seen]
            seen |= {a["id"] for a in alerts}
            _print_alerts(new, "new alerts" if not args.once else "alerts")
            if args.once:
                return 0
            time.sleep(max(1.0, args.interval - (time.time() - now)))
    except KeyboardInterrupt:
        print("watch: stopped")
        return 0
    finally:
        store.close()


def cmd_predict(args) -> int:
    from .detect import parse_duration
    from .predict import predict, write
    from .store import Store

    store = Store(args.db)
    doc = predict(store, _model(args), since_s=parse_duration(args.since))
    store.close()
    _print_alerts(doc["alerts"])
    if not args.no_write:
        md, js = write(doc, _out_dir(args))
        print(f"wrote {md}\nwrote {js}")
    return 0


def cmd_replay(args) -> int:
    from .predict import replay, replay_text

    model = _model(args)
    rc = 0
    for f in args.fixture:
        res = replay(f, model)
        print(json.dumps(res, indent=2) if args.json else replay_text(res))
        if any(x["lead_time_s"] is None for x in res["failures"]) or res["false_alarms"]:
            rc = 3
    return rc


def cmd_facts(args) -> int:
    from .builder import build

    _, facts, log, problems, _ = build(Path(args.repo))
    print(json.dumps({"facts": facts.facts, "checks": log, "address_problems": problems}, indent=2, default=str))
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="mindbridge", description="Find single points of failure, check Terraform plans, and warn before failures.")
    p.add_argument("--repo", default=str(REPO_ROOT), help="repo root (default: this checkout)")
    p.add_argument("--out-dir", help="report directory (default: <repo>/docs/mindbridge)")
    sub = p.add_subparsers(dest="cmd", required=True)

    w = sub.add_parser("whatif", help="N-1 sweep; writes whatif-report.md and .json")
    w.add_argument("--top", type=int, default=10, help="rows to print")
    w.set_defaults(func=cmd_whatif)

    pc = sub.add_parser("precheck", help="check `terraform show -json <planfile>` output")
    pc.add_argument("plan", help="plan JSON file")
    pc.add_argument("--layer", help="Terraform root the plan is for, e.g. aws/hub (inferred if omitted)")
    pc.add_argument("--threshold", type=float, help="block flows with weight >= this (default from rules.yaml)")
    pc.add_argument("--json", action="store_true", help="print JSON instead of text")
    pc.set_defaults(func=cmd_precheck)

    e = sub.add_parser("explain", help="optional AI explanation of the what-if report (needs ANTHROPIC_API_KEY)")
    e.add_argument("--report", help="whatif-report.json (default: <out-dir>/whatif-report.json)")
    e.add_argument("--alerts", help="alerts-*.json from predict (default: the newest in <out-dir>, if any)")
    e.add_argument("--no-alerts", action="store_true", help="explain the what-if report only")
    e.set_defaults(func=cmd_explain)

    f = sub.add_parser("facts", help="print what the builder read from Terraform")
    f.set_defaults(func=cmd_facts)

    wa = sub.add_parser("watch", help="poll the read-only collectors, store samples, run the detectors")
    wa.add_argument("--interval", type=float, default=60, help="loop tick in seconds (each collector keeps its own interval)")
    wa.add_argument("--once", action="store_true", help="run every collector once, print alerts, exit")
    wa.add_argument("--only", help="comma-separated collector names")
    wa.add_argument("--db", help="SQLite path (default: $MINDBRIDGE_DB or ~/.mindbridge/signals.db)")
    wa.add_argument("-v", "--verbose", action="store_true", help="print every sample")
    wa.set_defaults(func=cmd_watch)

    pr = sub.add_parser("predict", help="detectors over stored samples; writes alerts-<ts>.md/.json")
    pr.add_argument("--since", default="30m", help="window for fast signals, e.g. 30m, 2h (default 30m)")
    pr.add_argument("--db", help="SQLite path (default: $MINDBRIDGE_DB or ~/.mindbridge/signals.db)")
    pr.add_argument("--no-write", action="store_true", help="print only")
    pr.set_defaults(func=cmd_predict)

    rp = sub.add_parser("replay", help="stream a recorded or synthetic CSV series through the detectors; "
                                       "reports lead time and false alarms (exit 3 if a failure is missed "
                                       "or a false alarm fires)")
    rp.add_argument("fixture", nargs="+", help="CSV: ts,signal,component,value,unit,event[,note]")
    rp.add_argument("--json", action="store_true")
    rp.set_defaults(func=cmd_replay)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
