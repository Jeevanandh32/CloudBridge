"""Predict mode end to end: slow-burn fixtures, impact from the what-if model, store, collectors."""
import json
from pathlib import Path

import pytest

from mindbridge import collect
from mindbridge.collect import REGISTRY, Ctx, k8s_samples, parse_fw_output, run_collector, scrub
from mindbridge.detect import Sample
from mindbridge.explain import assert_clean, build_payload
from mindbridge.predict import Impact, SignalConfig, attach_impact, evaluate, predict, replay, to_markdown, write
from mindbridge.store import Store

SERIES = Path(__file__).resolve().parent / "fixtures" / "series"


@pytest.fixture(scope="session")
def model(built):
    return built[0]


@pytest.fixture(scope="session")
def replays(model):
    return {p.stem: replay(p, model) for p in sorted(SERIES.glob("*.csv"))}


def only_failure(res):
    assert len(res["failures"]) == 1
    return res["failures"][0]


# ---------------------------------------------------------------- slow-burn fixtures

def test_pod_ip_drain_warns_early_with_a_sensible_eta(replays):
    res = replays["pod-ip-drain"]
    f = only_failure(res)
    assert f["first_alert"] == "subnet.free_ips/cloudbridge-app-pod-a/time_to_threshold"
    assert f["lead_time_s"] >= 30 * 60
    assert "first_critical_at" in f and f["critical_lead_time_s"] >= 10 * 60
    # the ETA converges: within 15 min of the real crossing half-way through the lead time
    assert abs(f["eta_error_mid_s"]) <= 15 * 60
    assert abs(f["eta_error_last_s"]) <= 15 * 60
    assert res["false_alarms"] == []      # the flat 2b subnet stays quiet


def test_conntrack_ramp_warns_before_the_table_is_full(replays):
    res = replays["conntrack-ramp"]
    f = only_failure(res)
    assert f["first_alert"] == "fw.conntrack_pct/az-fw/time_to_threshold"
    assert f["lead_time_s"] >= 60 * 60
    # the alert is for 90 % of max, failure is 100 %: the predicted 90 % crossing comes first
    assert -45 * 60 <= f["eta_error_last_s"] <= 0
    assert res["false_alarms"] == []      # fw-a stays flat


def test_tunnel_loss_creep_caught_by_rtt_before_loss_is_user_visible(replays):
    res = replays["tunnel-loss"]
    f = only_failure(res)
    assert f["lead_time_s"] > 0
    assert f["first_alert"] == "path.rtt_ms/az-fw->10.10.0.10/baseline_deviation"
    assert res["false_alarms"] == []      # 10.10.0.74 hashes onto a healthy tunnel
    # a 20-packet ping resolves loss in 5 % steps: the loss detector itself only fires late
    loss = next(a for a in res["alerts"] if a["signal"] == "path.loss_pct")
    assert loss["classification"] == "late"


def test_real_session1_loss_ramp_is_the_before_case(replays):
    """Session 1's real samples (20 pings every ~5 min, 5 % steps): not predicted, 0 false alarms.
    Too few, too coarse points: refusing to alert is right; the probe was what needed fixing."""
    res = replays["slowburn-loss-real"]
    f = only_failure(res)
    assert f["lead_time_s"] is None and f["first_alert"] is None
    assert res["false_alarms"] == []
    assert not [a for a in res["alerts"] if a["classification"] == "early_warning"]
    # the early 100 % samples (path not up yet) must not count as "5 % reached"
    assert not [a for a in res["alerts"] if a["detector"] == "time_to_threshold"]


def test_fine_loss_probe_predicts_the_same_ramp(replays):
    """The same ramp (0 -> 8 % over 35 min) at 1-min samples and 0.5 % resolution is predicted
    before the 5 % crossing by the loss trend itself."""
    res = replays["tunnel-loss-fine"]
    f = only_failure(res)
    assert f["first_alert"] == "path.loss_pct/az-fw->10.10.0.10/time_to_threshold"
    assert f["lead_time_s"] >= 5 * 60
    assert abs(f["eta_error_last_s"]) <= 5 * 60
    assert res["false_alarms"] == []      # 10.10.0.74 stays quiet


def test_bgp_flap_warns_before_the_tunnel_stays_down(replays):
    res = replays["bgp-flap"]
    f = only_failure(res)
    assert f["lead_time_s"] >= 5 * 60
    assert set(f["detected_by"]) == {"vpn.tunnel_up/vpn-c1-t2/flap_counter", "azure.bgp_peer_up/vpn-c1-t2/flap_counter"}
    assert res["false_alarms"] == []


def test_budget_burn_projects_the_limit(replays):
    res = replays["budget-burn"]
    f = only_failure(res)
    assert f["first_alert"] == "budget.actual_usd/aws/time_to_threshold"
    assert f["lead_time_s"] >= 3 * 86400
    assert f["critical_lead_time_s"] >= 86400
    assert abs(f["eta_error_last_s"]) <= 12 * 3600


def test_healthy_noisy_series_raises_nothing(replays):
    res = replays["healthy-noisy"]
    assert res["failures"] == []
    assert res["alerts"] == [], [a["id"] for a in res["alerts"]]


def test_every_alert_has_impact_filled(replays):
    alerts = [a for r in replays.values() for a in r["alerts"]]
    assert alerts
    for a in alerts:
        imp = a["impact"]
        assert imp["answer"]
        if a["signal"].startswith("budget."):
            assert imp["component"] is None and imp["flows"] == []
        else:
            assert imp["component"] and imp["flows"], a["id"]


def test_impact_answers_which_flows_break_and_recovery(replays):
    ct = replays["conntrack-ramp"]["alerts"][0]["impact"]
    assert ct["component"] == "az-fw" and ct["recovery"] == "manual"
    broken = {f["flow"] for f in ct["flows"] if f["status"] == "broken"}
    assert {"azure-ingress", "aks-egress", "azure-to-aws"} <= broken
    flap = replays["bgp-flap"]["alerts"][0]["impact"]
    assert flap["component"] == "vpn-c1-t2"
    assert {f["recovery"] for f in flap["flows"] if f["status"] != "ok"} == {"auto"}
    assert all(f["recovery_s"] == 30 for f in flap["flows"] if f["status"] != "ok")   # measured silent failure
    pod = replays["pod-ip-drain"]["alerts"][0]["impact"]
    assert pod["component"] == "eks-node-a" and pod["component_status"] == "planned"
    assert "planned, not yet in code" in pod["answer"]


def test_ambiguous_path_lists_candidates(replays):
    rtt = next(a for a in replays["tunnel-loss"]["alerts"] if a["signal"] == "path.rtt_ms")
    cands = {c["component"] for c in rtt["impact"]["candidates"]}
    assert cands == {"vpn-c0-t1", "vpn-c0-t2", "vpn-c1-t1", "vpn-c1-t2", "fw-a"}
    assert "cannot tell" in rtt["impact"]["note"]


# ---------------------------------------------------------------- mapping, quotas, countdown

def test_signal_section_maps_to_real_components(model):
    cfg = SignalConfig.from_model(model)
    for sig, d in cfg.defs.items():
        for target in (d.get("map") or {}).values():
            for t in target if isinstance(target, list) else [target]:
                assert t in model.components, (sig, t)
    assert set(cfg.collectors) == set(REGISTRY)


def test_quota_and_domain_countdown(model):
    cfg = SignalConfig.from_model(model)
    now = 1_800_000_000.0
    s = [Sample(now, "quota.azure_public_ips", "northcentralus", 3, "count"),
         Sample(now, "quota.azure_public_ips.limit", "northcentralus", 3, "count"),
         Sample(now, "domain.expiry_days", "jeevs.click", 14.5, "days")]
    # evaluated 12 h after the samples: the countdown ages the domain sample to 14 days
    alerts = attach_impact(evaluate(s, cfg, now=now + 43200), Impact(model, cfg))
    by = {a["detector"]: a for a in alerts}
    q = by["quota_headroom"]
    assert q["severity"] == "warning" and q["metrics"]["free"] == 0
    assert q["impact"]["component"] is None and q["impact"]["fixes_needing_it"]
    d = by["countdown"]
    assert d["severity"] == "warning" and d["metrics"]["days_left"] == pytest.approx(14)
    assert d["impact"]["component"] == "registrar"
    assert any(f["flow"] == "domain-control" and f["status"] == "broken" for f in d["impact"]["flows"])


def test_counter_rate_transform(model):
    cfg = SignalConfig.from_model(model)
    s = [Sample(i * 300, "fw.nft_drop_total", "az-fw", 500 * i, "packets") for i in range(12)]
    s += [Sample((12 + i) * 300, "fw.nft_drop_total", "az-fw", 6000 + 30000 * (i + 1), "packets") for i in range(3)]
    alerts = evaluate(s, cfg, now=s[-1].ts)
    assert [a["signal"] for a in alerts] == ["fw.nft_drop_total"]
    assert alerts[0]["evidence"][0]["unit"] == "packets/min"


# ---------------------------------------------------------------- store, predict, write

def test_store_refuses_the_repo(tmp_path):
    from mindbridge.model import REPO_ROOT
    with pytest.raises(ValueError):
        Store(REPO_ROOT / "signals.db")


def test_store_env_override_and_dedupe(tmp_path, monkeypatch):
    monkeypatch.setenv("MINDBRIDGE_DB", str(tmp_path / "s.db"))
    st = Store()
    assert st.path == (tmp_path / "s.db").resolve()
    smp = Sample(100.0, "x", "c", 1.0, "u")
    st.add_samples([smp, smp])
    st.add_run("aws_vpn", "unavailable", "not deployed")
    assert len(st.samples()) == 1
    assert st.last_runs()[0]["status"] == "unavailable"
    st.close()


def test_predict_writes_alert_files(tmp_path, model):
    st = Store(tmp_path / "s.db")
    now = 1_800_000_000.0
    st.add_samples([Sample(now - 3600 + 60 * i, "subnet.free_ips", "cloudbridge-app-pod-a", 200 - 3 * i, "count")
                    for i in range(60)])
    doc = predict(st, model, since_s=1800, now=now)
    assert [a["id"] for a in doc["alerts"]] == ["subnet.free_ips/cloudbridge-app-pod-a/time_to_threshold"]
    md, js = write(doc, tmp_path / "out")
    assert md.name.startswith("alerts-") and md.suffix == ".md" and js.suffix == ".json"
    assert "eks-node-a" in md.read_text()
    data = json.loads(js.read_text())
    assert data["alerts"][0]["impact"]["flows"]
    assert "No alerts" in to_markdown({**doc, "alerts": []})


def test_explain_payload_includes_alerts_and_is_clean(report, model, replays):
    doc = {"generated": "2026-11-24T16:00:00Z", "alerts": replays["conntrack-ramp"]["alerts"]}
    payload = build_payload(report, model, doc)
    text = json.dumps(payload)
    assert_clean(text)
    a = payload["alerts"][0]
    assert a["eta_s"] is not None and a["impact"]["component"] == "az-fw" and a["impact"]["flows"]
    assert "alerts" not in build_payload(report, model)


# ---------------------------------------------------------------- collectors degrade cleanly

def test_collectors_skip_when_cli_missing(monkeypatch):
    monkeypatch.setattr(collect.shutil, "which", lambda name: None)
    cfg_targets = {"aws_region": "us-east-2"}
    for name, c in REGISTRY.items():
        res = run_collector(c, cfg_targets, timeout_s=5)
        assert res.status == "unavailable", name
        assert res.samples == []


def test_collector_timeout_is_unavailable(monkeypatch):
    import subprocess

    def slow(*a, **k):
        raise subprocess.TimeoutExpired(a[0], k.get("timeout"))
    monkeypatch.setattr(collect.subprocess, "run", slow)
    monkeypatch.setattr(collect.shutil, "which", lambda name: "/usr/bin/" + name)
    res = run_collector(REGISTRY["aws_subnets"], {"aws_region": "us-east-2", "project_tag": "cloudbridge"}, timeout_s=5)
    assert res.status == "unavailable" and "timed out" in res.message


def test_loss_trend_needs_fine_data():
    from mindbridge.detect import time_to_threshold

    kw = dict(threshold=5, window_s=900, min_samples=10, r2_min=0.4, min_rise=2.5, horizon_s=1800,
              critical_s=600, beyond_median=3, max_spacing_s=120)
    ramp = [Sample(60.0 * i, "path.loss_pct", "p", 0.25 * i, "pct") for i in range(16)]   # 0 -> 3.75 %
    f = time_to_threshold(ramp, **kw)
    assert f is not None and 0 < f.eta_s <= 600   # 5 min away: critical (<= 10 min)
    assert f.severity == "critical"
    coarse = [Sample(300.0 * i, "path.loss_pct", "p", 0.25 * 5 * i, "pct") for i in range(4)]
    assert time_to_threshold(coarse, **kw) is None                  # 5-min samples: too coarse
    one_bad = [Sample(60.0 * i, "path.loss_pct", "p", 100.0 if i == 14 else 0.0, "pct") for i in range(15)]
    assert time_to_threshold(one_bad, **kw) is None                 # one 100 % sample is not "reached"
    flat_noise = [Sample(60.0 * i, "path.loss_pct", "p", [0, 0.5, 1.0][i % 3], "pct") for i in range(16)]
    assert time_to_threshold(flat_noise, **kw) is None


def test_fw_output_cpu_pps_and_conntrack_labels():
    ctx = Ctx({"fw_pps_limit": {"fw-a": 60000}}, 10, now=1000.0)
    text = ("cpu_a=cpu  1000 0 500 8000 100 0 50 20 0 0\nnet_a=100000 90000\nt_a=1000.0\n"
            "cpu_b=cpu  1600 0 800 8400 100 0 150 70 0 0\nnet_b=150000 140000\nt_b=1010.0\n"
            "loadavg=0.42 0.30 0.20\nconntrack_count=8600\nconntrack_max=1048576\n")
    v = {(s.signal, s.component): s for s in parse_fw_output(text, "fw-a", ctx, 64512)}
    # busy = (1600-1000)+(800-500)+(150-50)+(70-20) = 1050 of 1450 jiffies
    assert v[("fw.cpu_pct", "fw-a")].value == pytest.approx(100 * 1050 / 1450, abs=0.01)
    assert v[("fw.cpu_steal_pct", "fw-a")].value == pytest.approx(100 * 50 / 1450, abs=0.01)
    assert v[("fw.pps", "fw-a")].value == pytest.approx(10000)
    assert v[("fw.pps_limit", "fw-a")].value == 60000
    assert v[("fw.load1", "fw-a")].value == 0.42
    # the real AWS limit and peak (Session 1): count and max labelled correctly, < 1 %
    assert v[("fw.conntrack_max", "fw-a")].value == 1048576
    assert v[("fw.conntrack_count", "fw-a")].value == 8600
    assert v[("fw.conntrack_pct", "fw-a")].value == pytest.approx(0.82, abs=0.01)


def test_azure_conntrack_sample_is_a_count_not_a_max():
    ctx = Ctx({}, 10, now=1000.0)
    v = {s.signal: s for s in parse_fw_output("conntrack_count=7168\nconntrack_max=262144\n", "az-fw", ctx, 64512)}
    assert v["fw.conntrack_count"].value == 7168 and v["fw.conntrack_max"].value == 262144
    # a swapped pair is reported, never turned into a > 100 % reading
    ctx = Ctx({}, 10, now=1000.0)
    out = parse_fw_output("conntrack_count=1048576\nconntrack_max=7168\n", "az-fw", ctx, 64512)
    assert "fw.conntrack_pct" not in {s.signal for s in out} and "check the labels" in ctx.notes[0]


def test_design_capacity_uses_the_measured_limit(model):
    cap = model.data["capacity"]
    for fw in ("fw-a", "fw-b"):
        assert cap[fw]["conntrack_max"] == 1048576 and cap[fw]["conntrack_peak"] == 8600
        assert set(cap[fw]["binding_limits"]) == {"cpu", "pps"}
    assert cap["az-fw"]["conntrack_count_sample"] == 7168 and cap["az-fw"]["conntrack_max"] is None
    assert "7168" not in json.dumps({k: v for k, v in cap.items() if k != "az-fw"})


def test_cpu_and_pps_trends_alert(model):
    cfg = SignalConfig.from_model(model)
    s = []
    for i in range(12):
        t = 300.0 * i
        s.append(Sample(t, "fw.pps", "fw-a", 10000 + 4000 * i, "pps"))
        s.append(Sample(t, "fw.pps_limit", "fw-a", 60000, "pps"))
        s.append(Sample(t, "fw.cpu_pct", "fw-b", 20 + 5 * i, "pct"))
    alerts = attach_impact(evaluate(s, cfg, now=s[-1].ts), Impact(model, cfg))
    by = {a["id"]: a for a in alerts}
    pps = by["fw.pps/fw-a/time_to_threshold"]
    assert pps["eta_s"] == pytest.approx(300 * (60000 - 54000) / 4000, rel=0.01)
    assert pps["impact"]["component"] == "fw-a"
    assert "fw.cpu_pct/fw-b/time_to_threshold" in by


def test_azure_probe_is_fine_and_combined():
    from mindbridge.collect import fw_script, ping_script
    from mindbridge.model import Model

    m = Model.load()
    t = m.data["signals"]["targets"]
    col = m.data["signals"]["collectors"]["azure_firewall"]
    assert (t["ping_count"], t["ping_interval_s"], t["ping_rounds"]) == (200, 0.2, 2)
    # 2 rounds x 40 s plus Run Command overhead fit inside the interval: one loss sample per minute
    assert col["interval"] == 120 and col["timeout"] >= 2 * 200 * 0.2 + 40
    script = fw_script(ping_script(t, ["10.10.0.10", "10.10.0.74"]))
    assert "ping -c 200 -i 0.2" in script and "conntrack" in script and "/proc/net/dev" in script
    assert script.index("snap a") < script.index("ping -c") < script.index("snap b")


def test_ping_lines_carry_their_own_timestamps():
    ctx = Ctx({}, 10, now=5000.0)
    out = parse_fw_output("ping 10.10.0.10 ts=4880 loss=1.5 rtt=19.2\nping 10.10.0.10 ts=4940 loss=2 rtt=19.4\n",
                          "az-fw", ctx, 64512)
    loss = [(s.ts, s.value) for s in out if s.signal == "path.loss_pct"]
    assert loss == [(4880.0, 1.5), (4940.0, 2.0)]


def test_scrub_removes_ids():
    t = scrub("arn:aws:iam::123456789012:user/x in 123456789012 sub 00000000-0000-0000-0000-000000000000 a@b.io")
    assert "123456789012" not in t and "0000-0000" not in t and "a@b.io" not in t


def test_fw_output_parser():
    ctx = Ctx({}, 10, now=1000.0)
    out = parse_fw_output("conntrack_count=900\nconntrack_max=1000\nsnat_entries=4000\nsnat_top_dest=3225\n"
                          "nft_invalid=12\nnft_drop=345\n"
                          "ping 10.10.0.10 loss=5 rtt=31.2\nping 10.10.0.74 loss=100 rtt=\n", "az-fw", ctx, 64512)
    v = {(s.signal, s.component): s.value for s in out}
    assert v[("fw.conntrack_pct", "az-fw")] == 90.0
    assert v[("fw.nat_ports_pct", "az-fw")] == pytest.approx(5.0, abs=0.01)
    assert v[("fw.nft_drop_total", "az-fw")] == 345
    assert v[("path.loss_pct", "az-fw->10.10.0.10")] == 5
    assert v[("path.loss_pct", "az-fw->10.10.0.74")] == 100
    assert ("path.rtt_ms", "az-fw->10.10.0.74") not in v


def test_k8s_parser():
    now = 1_800_000_000.0
    ctx = Ctx({}, 10, now=now)
    recent = "2027-01-15T08:00:00Z"   # = now
    pods = {"items": [
        {"status": {"conditions": [{"type": "PodScheduled", "status": "False", "reason": "Unschedulable"}]}},
        {"status": {"conditions": [{"type": "PodScheduled", "status": "True"}],
                    "containerStatuses": [{"state": {"waiting": {"reason": "ContainerCreating"}}}]}}]}
    nodes = {"items": [
        {"metadata": {"labels": {"topology.kubernetes.io/zone": "us-east-2a"}},
         "status": {"conditions": [{"type": "Ready", "status": "True"}, {"type": "DiskPressure", "status": "True"}]}},
        {"metadata": {"labels": {"topology.kubernetes.io/zone": "us-east-2b"}},
         "status": {"conditions": [{"type": "Ready", "status": "True"}]}}]}
    events = {"items": [
        {"reason": "FailedCreatePodSandBox", "lastTimestamp": recent,
         "message": "plugin type=\"aws-cni\" failed (add): add cmd: failed to assign an IP address to container"},
        {"reason": "FailedCreatePodSandBox", "lastTimestamp": "2020-01-01T00:00:00Z", "message": "old"},
        {"reason": "SpotInterruption", "lastTimestamp": recent, "message": "2 minute warning"}]}
    out = {(s.signal, s.component): s for s in k8s_samples(ctx, "cloudbridge-eks", pods, nodes, events)}
    assert out[("k8s.pending_pods", "cloudbridge-eks")].value == 2
    assert "Unschedulable x1" in out[("k8s.pending_pods", "cloudbridge-eks")].detail
    assert out[("k8s.node_bad_conditions", "cloudbridge-eks:us-east-2a")].value == 1
    assert out[("k8s.node_bad_conditions", "cloudbridge-eks:us-east-2b")].value == 0
    assert out[("k8s.sandbox_failures", "cloudbridge-eks")].value == 1
    assert out[("k8s.ip_assign_errors", "cloudbridge-eks")].value == 1
    assert out[("k8s.spot_events", "cloudbridge-eks")].value == 1


# ---------------------------------------------------------------- Session 2: aligned /28s, pod-IP mode

def test_aligned_28_math_empty_and_reserved():
    from mindbridge.collect import aws_reserved, free_aligned_blocks, free_ip_count

    assert aws_reserved("10.10.0.0/26") == ["10.10.0.0", "10.10.0.1", "10.10.0.2", "10.10.0.3", "10.10.0.63"]
    # a /26 has 4 aligned /28s; the first and last hold reserved addresses, so at most 2 are free
    assert free_aligned_blocks("10.10.0.0/26", []) == 2
    assert free_ip_count("10.10.0.0/26", []) == 59
    assert free_aligned_blocks("10.10.0.64/26", ["10.10.0.70"]) == 2        # .64/28 holds reserved .64-.67 anyway
    assert free_aligned_blocks("10.10.0.64/26", ["10.10.0.80"]) == 1        # .80/28 taken
    assert free_aligned_blocks("10.10.0.64/26", ["10.10.0.80", "10.10.0.100"]) == 0
    # a /19 pod subnet: 512 blocks, 510 can be free; a delegated prefix takes its block
    assert free_aligned_blocks("10.10.64.0/19", []) == 510
    assert free_aligned_blocks("10.10.64.0/19", ["10.10.64.10"], ["10.10.64.16/28", "10.10.80.0/28"]) == 508
    # a bigger prefix (or one outside the subnet) is handled by range
    assert free_aligned_blocks("10.10.64.0/19", [], ["10.10.65.0/24"]) == 494
    assert free_aligned_blocks("10.10.0.0/26", [], ["10.10.0.64/28"]) == 2


def test_fragmented_26_has_40_free_ips_but_no_aligned_28():
    """Session 2: 'failed to assign an IP address' with 34-49 free IPs in the /26 node subnets."""
    from mindbridge.collect import free_aligned_blocks, free_ip_count

    # 19 scattered secondary IPs and ENI primaries: blocks 1 (.16-.31) and 2 (.32-.47) each get some
    used = ["10.10.0.5", "10.10.0.9", "10.10.0.12", "10.10.0.15", "10.10.0.19", "10.10.0.23", "10.10.0.27",
            "10.10.0.36", "10.10.0.41", "10.10.0.44", "10.10.0.49", "10.10.0.50", "10.10.0.52", "10.10.0.53",
            "10.10.0.55", "10.10.0.57", "10.10.0.58", "10.10.0.60", "10.10.0.62"]
    assert free_ip_count("10.10.0.0/26", used) == 40
    assert free_aligned_blocks("10.10.0.0/26", used) == 0
    # the same 19 IPs packed at the top of the subnet would leave both usable /28s free
    packed = [f"10.10.0.{i}" for i in list(range(4, 16)) + list(range(48, 55))]
    assert free_ip_count("10.10.0.0/26", packed) == 40
    assert free_aligned_blocks("10.10.0.0/26", packed) == 2


def test_aligned28_samples_from_describe_output():
    from mindbridge.collect import aligned28_samples

    ctx = Ctx({}, 10, now=1000.0)
    subnets = [{"n": "cloudbridge-app-node-a", "c": "10.10.0.0/26", "i": "subnet-a", "f": 40},
               {"n": "cloudbridge-app-pod-a", "c": "10.10.64.0/19", "i": "subnet-p", "f": 8154}]
    enis = [{"s": "subnet-a", "ips": ["10.10.0.20", "10.10.0.40"], "p": None},
            {"s": "subnet-p", "ips": [], "p": ["10.10.64.16/28", "10.10.64.32/28"]}]
    out = {s.component: s for s in aligned28_samples(ctx, subnets, enis)}
    assert out["cloudbridge-app-node-a"].value == 0 and out["cloudbridge-app-node-a"].unit == "blocks"
    assert "0 of 4 aligned /28s free; 40 free IPs" == out["cloudbridge-app-node-a"].detail
    assert out["cloudbridge-app-pod-a"].value == 508


def test_k8s_parser_reads_pod_ip_mode():
    ctx = Ctx({}, 10, now=1000.0)
    lab = lambda m, z: {"metadata": {"labels": {"cloudbridge.io/pod-ip-mode": m, "topology.kubernetes.io/zone": z}},
                        "status": {"conditions": [{"type": "Ready", "status": "True"}]}}
    # mid-roll: one old node, two new ones
    nodes = {"items": [lab("secondary-ip", "us-east-2a"), lab("prefix", "us-east-2a"), lab("prefix", "us-east-2b")]}
    out = {s.component: s.value for s in k8s_samples(ctx, "cloudbridge-eks", {}, nodes, {})
           if s.signal == "k8s.pod_ip_mode"}
    assert out == {"cloudbridge-eks:prefix": 2, "cloudbridge-eks:secondary-ip": 1,
                   "cloudbridge-eks:prefix-custom-net": 0, "cloudbridge-eks:secondary-ip-custom-net": 0}
    # no label (AKS): no mode samples
    aks = {"items": [{"metadata": {"labels": {}}, "status": {"conditions": []}}]}
    assert not [s for s in k8s_samples(ctx, "cloudbridge-aks", {}, aks, {}) if s.signal == "k8s.pod_ip_mode"]


def _aligned_series(comp, values, step=60.0):
    return [Sample(step * i, "subnet.free_aligned_28", comp, v, "blocks") for i, v in enumerate(values)]


def _mode(comp_mode, n_nodes, ts):
    return [Sample(t, "k8s.pod_ip_mode", f"cloudbridge-eks:{comp_mode}", n_nodes, "nodes") for t in ts]


def test_aligned_28_detector_runs_only_in_prefix_mode(model):
    cfg = SignalConfig.from_model(model)
    drain = _aligned_series("cloudbridge-app-pod-a", [40 - 3 * i for i in range(12)])   # /19 pod subnet draining
    ts = [s.ts for s in drain]
    aid = "subnet.free_aligned_28/cloudbridge-app-pod-a/time_to_threshold"
    # custom networking + prefix: pods draw /28s from the pod subnets -> trend alert
    on = evaluate(drain + _mode("prefix-custom-net", 2, ts) + _mode("prefix", 0, ts), cfg, now=ts[-1])
    a = next(a for a in on if a["id"] == aid)
    assert a["eta_s"] == pytest.approx(60 * 7 / 3, rel=0.05)
    # secondary-IP mode: the same numbers mean nothing, no alert
    off = evaluate(drain + _mode("secondary-ip", 2, ts) + _mode("prefix-custom-net", 0, ts), cfg, now=ts[-1])
    assert aid not in {a["id"] for a in off}
    # mode unknown (no kubernetes samples): gate closed
    assert aid not in {a["id"] for a in evaluate(drain, cfg, now=ts[-1])}


def test_fragmented_node_subnet_alerts_in_prefix_mode(model):
    """The Session 2 case: /26 node subnet in prefix mode, 0 free aligned /28s -> critical, with impact."""
    cfg = SignalConfig.from_model(model)
    ser = _aligned_series("cloudbridge-app-node-a", [1, 1, 0])
    ts = [s.ts for s in ser]
    alerts = attach_impact(evaluate(ser + _mode("prefix", 2, ts), cfg, now=ts[-1]), Impact(model, cfg))
    a = next(a for a in alerts if a["signal"] == "subnet.free_aligned_28")
    assert a["severity"] == "critical" and a["eta_s"] == 0
    assert a["impact"]["component"] == "eks-node-a"
    # with custom networking the node subnets no longer matter
    assert not evaluate(ser + _mode("prefix-custom-net", 2, ts) + _mode("prefix", 0, ts), cfg, now=ts[-1])


def test_gate_ignores_a_stale_mode_sample(model):
    cfg = SignalConfig.from_model(model)
    ser = _aligned_series("cloudbridge-app-node-a", [0], step=1.0)
    ser = [Sample(10_000.0, s.signal, s.component, s.value, s.unit) for s in ser]
    stale = _mode("prefix", 2, [10_000.0 - 3600])
    assert not evaluate(ser + stale, cfg, now=10_000.0)


# ---------------------------------------------------------------- Session 2: probe targets follow the topology

def _fake_run(responses):
    """Ctx.run stand-in: the first response whose key is in the command line answers it."""
    calls = []

    def run(self, args, parse_json=True, timeout=None):
        line = " ".join(args)
        calls.append(line)
        for key, val in responses:
            if key in line:
                if isinstance(val, Exception):
                    raise val
                return val(line) if callable(val) else val
        raise AssertionError("unexpected command: " + line)
    return run, calls


def _probe_targets():
    from mindbridge.model import Model
    return dict(Model.load().data["signals"]["targets"])


def test_absent_probe_target_gives_no_loss_samples(monkeypatch):
    """Session 2: the test host 10.10.0.10 did not exist (enable_test_hosts=false); pinging it
    anyway gave a false 100 % loss alarm. An absent target is skipped and gives no samples."""
    targets = _probe_targets()
    # what the firewall would print if the absent host were pinged anyway
    out_all = ("[stdout]\nconntrack_count=10\nconntrack_max=262144\n"
               "ping 10.10.0.10 ts=990 loss=100 rtt=\nping 10.10.0.74 ts=990 loss=100 rtt=\n"
               "ping 10.10.0.21 ts=990 loss=0 rtt=19.0\n[stderr]\n")
    pods = {"items": [{"metadata": {"name": "frontend-1"},
                       "status": {"phase": "Running", "podIP": "10.10.0.21",
                                  "conditions": [{"type": "Ready", "status": "True"}]}}]}
    run, calls = _fake_run([
        ("vm show", "cloudbridge-fw"),
        ("describe-instances", []),                      # no test hosts
        ("get pods", pods),                              # one frontend pod in 2a, none in 2b
        ("run-command invoke", out_all),
    ])
    monkeypatch.setattr(collect.Ctx, "run", run)
    monkeypatch.setattr(collect.shutil, "which", lambda name: "/usr/bin/" + name)
    res = run_collector(REGISTRY["azure_firewall"], targets, timeout_s=30, now=1000.0)
    loss = {s.component: s for s in res.samples if s.signal == "path.loss_pct"}
    assert set(loss) == {"az-fw->eks-pod-a"} and loss["az-fw->eks-pod-a"].detail == "10.10.0.21"
    assert not [s for s in res.samples if "10.10.0.10" in s.component or "app-host" in s.component]
    script = next(c for c in calls if "run-command invoke" in c)
    assert "10.10.0.10" not in script and "10.10.0.74" not in script and "10.10.0.21" in script
    assert res.status == "partial"
    for name in ("app-host-a", "app-host-b", "eks-pod-b"):
        assert f"probe {name}: unavailable: target absent" in res.message


def test_no_probe_target_present_runs_counters_only(monkeypatch):
    targets = _probe_targets()
    run, calls = _fake_run([
        ("vm show", "cloudbridge-fw"),
        ("describe-instances", []),
        ("get pods", collect.Unavailable("cluster unreachable (not deployed or endpoint gone)")),
        ("run-command invoke", "[stdout]\nconntrack_count=10\nconntrack_max=262144\nping 10.10.0.10 ts=990 loss=100 rtt=\n"),
    ])
    monkeypatch.setattr(collect.Ctx, "run", run)
    monkeypatch.setattr(collect.shutil, "which", lambda name: "/usr/bin/" + name)
    res = run_collector(REGISTRY["azure_firewall"], targets, timeout_s=30, now=1000.0)
    assert not [s for s in res.samples if s.signal.startswith("path.")]
    assert {s.signal for s in res.samples} >= {"fw.conntrack_pct"}
    script = next(c for c in calls if "run-command invoke" in c)
    assert "ping -c" not in script and "sleep 10" in script


def test_present_test_host_is_probed_by_name(monkeypatch):
    targets = dict(_probe_targets(), path_probe_targets=[
        {"name": "app-host-a", "resolve": "aws_instance", "tag": "cloudbridge-app-host-a", "ip": "10.10.0.10"}])
    run, _ = _fake_run([
        ("vm show", "cloudbridge-fw"),
        ("describe-instances", ["10.10.0.10"]),
        ("run-command invoke", "[stdout]\nping 10.10.0.10 ts=990 loss=1.5 rtt=19.2\n"),
    ])
    monkeypatch.setattr(collect.Ctx, "run", run)
    monkeypatch.setattr(collect.shutil, "which", lambda name: "/usr/bin/" + name)
    res = run_collector(REGISTRY["azure_firewall"], targets, timeout_s=30, now=1000.0)
    assert res.status == "ok"
    loss = [s for s in res.samples if s.signal == "path.loss_pct"]
    assert [(s.component, s.value, s.detail) for s in loss] == [("az-fw->app-host-a", 1.5, "10.10.0.10")]


def test_pick_pod_ip_by_cidr():
    from mindbridge.collect import pick_pod_ip

    pod = lambda n, ip, phase="Running", ready="True": {"metadata": {"name": n}, "status": {
        "phase": phase, "podIP": ip, "conditions": [{"type": "Ready", "status": ready}]}}
    pods = {"items": [pod("a", "10.10.0.90"), pod("b", "10.10.70.4", ready="False"), pod("c", "10.10.65.9"),
                      pod("d", "10.10.0.20", phase="Pending")]}
    assert pick_pod_ip(pods, ["10.10.0.0/26", "10.10.64.0/19"]) == "10.10.65.9"
    assert pick_pod_ip(pods, ["10.10.0.64/26", "10.10.96.0/19"]) == "10.10.0.90"
    assert pick_pod_ip({"items": []}, None) is None
