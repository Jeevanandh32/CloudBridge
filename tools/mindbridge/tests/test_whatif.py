"""N-1 sweep on the current design."""


def flow(row, fid):
    return next(f for f in row["flows"] if f["flow"] == fid)


def test_baseline_all_ok(report):
    assert all(f["status"] == "ok" for f in report["baseline"].values())
    assert report["baseline_absent"] == []


def test_single_azure_firewall_is_high_and_manual(rows):
    r = rows["az-fw"]
    assert r["band"] == "high"
    assert r["recovery"] == "manual"
    for fid in ("azure-ingress", "aks-egress", "dns-aws-to-azure", "dns-azure-to-aws", "azure-to-aws"):
        f = flow(r, fid)
        assert f["status"] == "broken", fid
        assert f["recovery"] == "manual", fid
    # users still reach the app on AWS, but there is no failover left
    users = flow(r, "users-app")
    assert users["status"] == "ok"
    assert "no fallback" in users["note"]


def test_azure_firewall_is_worst_infrastructure_risk(report):
    infra = [r for r in report["rows"] if r["section"] == "infrastructure"]
    assert infra[0]["component"] == "az-fw"


def test_aws_firewalls_pinned_half_manual(rows):
    for fw in ("fw-a", "fw-b"):
        r = rows[fw]
        assert r["worst_status"] == "degraded"
        for fid in ("aws-egress", "azure-to-aws"):
            f = flow(r, fid)
            assert f["status"] == "degraded"
            assert f["impact_pct"] == 50.0
            assert f["recovery"] == "manual"
        # DNS forwarding to the AWS firewalls fails over: Azure lists both
        dns = flow(r, "dns-azure-to-aws")
        assert dns["recovery"] == "auto"


def test_one_azure_gateway_instance_degraded_auto(rows):
    for inst in ("az-vpngw-i0", "az-vpngw-i1"):
        r = rows[inst]
        assert r["worst_status"] == "degraded"
        assert all(f["status"] != "broken" for f in r["flows"])
        f = flow(r, "azure-to-aws")
        assert f["impact_pct"] == 50.0
        assert f["recovery"] == "auto"
        assert f["recovery_s"] == 30            # measured silent failure (hold timer), was 90
        assert f["redundancy_s"] == 860         # measured 14 min 20 s to rebuild the tunnels
        # an instance loss is a silent failure only
        assert set(r["failure_modes"]) == {"silent"}
        assert r["summary"] == "users recover in ~30 s; redundancy is reduced for ~14 min"


def test_reduced_redundancy_window_adds_severity(built, rows):
    model = built[0]
    f = flow(rows["az-vpngw-i0"], "azure-to-aws")
    # 7 x 0.5 x (1 + 30/60) for the outage + 7 x 0.5 x min(3, 860/600) for the window
    assert f["severity"] == round(7 * 0.5 * 1.5 + 7 * 0.5 * (860 / 600), 2)
    assert model.scoring["reduced_redundancy"] == {"per_s": 600, "cap": 3}


def test_bgp_failure_modes_reported_both_and_labelled(rows):
    for cid in ("vpn-c0-t1", "aws-vpn-c0"):
        r = rows[cid]
        fms = r["failure_modes"]
        assert set(fms) == {"clean", "silent"}
        assert fms["clean"]["name"] == "clean withdrawal" and fms["silent"]["name"] == "silent failure"
        # clean: measured 0 of 16 flows hit; the flows only lose redundancy
        assert fms["clean"]["severity"] == 0
        assert all(f["status"] == "ok" and f["redundancy_lost_pct"] > 0 for f in fms["clean"]["flows"])
        assert fms["clean"]["summary"].startswith("no flow loses packets")
        assert fms["silent"]["recovery_s"] == 30
        # the row is scored on the worse mode
        assert r["failure_mode"] == "silent" and r["severity"] == fms["silent"]["severity"]
    assert "API" in rows["aws-vpn-c0"]["failure_modes"]["clean"]["cause"]
    assert flow(rows["vpn-c0-t1"], "azure-to-aws")["impact_pct"] == 25.0


def test_measured_recovery_times(built):
    rt = built[0].recovery_times
    assert "bgp_hold_s" not in rt
    for key, value in (("bgp_silent_s", 30), ("bgp_clean_withdrawal_s", 0), ("azure_gw_instance_rebuild_s", 860),
                       ("tgw_route_convergence_s", 5), ("appliance_mode_transition_s", 840)):
        assert rt[key]["value"] == value, key
        assert "measured 2026-11-23" in rt[key]["source"], key


def test_one_tunnel_is_a_quarter(rows):
    f = flow(rows["vpn-c0-t1"], "azure-to-aws")
    assert (f["status"], f["impact_pct"], f["recovery"]) == ("degraded", 25.0, "auto")


def test_vpn_connection_loss_not_double_counted(rows):
    f = flow(rows["aws-vpn-c0"], "azure-to-aws")
    assert f["impact_pct"] == 50.0


def test_management_plane_risks(rows):
    s = rows["tf-state-bucket"]
    assert s["section"] == "management"
    assert flow(s, "change-path")["status"] == "broken"
    assert s["recovery"] == "manual"
    reg = rows["registrar"]
    assert reg["section"] == "management"
    assert flow(reg, "domain-control")["status"] == "broken"
    # neither touches a data path
    for r in (s, reg):
        assert {f["flow"] for f in r["flows"]} <= {"change-path", "domain-control"}


def test_losing_alb_fails_over_to_azure(rows):
    users = flow(rows["aws-alb"], "users-app")
    assert users["status"] == "degraded"
    assert users["recovery"] == "auto"
    assert users["recovery_s"] == 40  # measured in Tests 1-2, was the 90 s estimate
    assert rows["aws-alb"]["status"] == "planned"


def test_one_dns_provider_is_survivable(rows):
    users = flow(rows["dns-route53"], "users-app")
    assert users["status"] == "degraded" and users["recovery"] == "auto"


def test_config_risks_are_separate(rows):
    assert rows["tgw-prop-app-to-inspection"]["section"] == "config"
    assert rows["tgw-appliance-mode"]["section"] == "config"


def test_appliance_mode_scoped_to_vpc_vpc_with_transition_risk(rows):
    r = rows["tgw-appliance-mode"]
    # every current flow through it is VPN<->VPC: measured unaffected with appliance mode off
    assert r["flows"] == [] and r["severity"] == 0
    t = r["transition_risk"]
    assert t["attribute"] == "appliance_mode_support" and t["window_s"] == 840 and t["success_pct"] == [22, 40]
    assert "maintenance window" in t["summary"]


def test_appliance_mode_still_matters_for_vpc_vpc_flows(built):
    from mindbridge.model import Model

    data = built[0].data_with_state()
    data["flows"].append({"id": "spoke-to-spoke", "name": "VPC <-> VPC across AZs", "weight": 5, "path": "vpc-vpc",
                          "hops": ["aws-tgw", "tgw-att-inspection", "appliance-mode", "inspection-fw"]})
    m = Model(data)
    fr = m.eval_all({"tgw-appliance-mode"})
    assert fr["spoke-to-spoke"].status == "degraded" and fr["spoke-to-spoke"].impact == 0.5
    assert fr["azure-to-aws"].status == "ok"


def test_fixes_respect_constraints(rows):
    fixes = rows["az-fw"]["fixes"]
    second_vm = next(f for f in fixes if "Second firewall VM" in f["mitigation"])
    assert second_vm["blocked"]
    assert any("azure_bseries_vcpu" in b for b in second_vm["blocked_by"])
    assert any("azure_public_ips" in b for b in second_vm["blocked_by"])
    assert any(not f["blocked"] for f in fixes)
    nfw = next(f for f in rows["fw-a"]["fixes"] if "Network Firewall" in f["mitigation"])
    assert nfw["blocked"] and any("budget" in b for b in nfw["blocked_by"])
    gwlb = next(f for f in rows["fw-a"]["fixes"] if "Gateway Load Balancer" in f["mitigation"])
    assert not gwlb["blocked"]


def test_planned_components_flagged(report):
    planned = [r for r in report["rows"] if r["status"] == "planned"]
    assert {r["component"] for r in planned} >= {"eks-node-a", "aks-node", "dns-route53", "registrar"}
    assert all(r["layer"] == "planned" and r["planned_layer"] for r in planned)


def test_markdown_written(report, tmp_path):
    from mindbridge.whatif import write

    md, js = write(report, tmp_path)
    text = md.read_text()
    assert "planned (azure/aks), not yet in code" in text
    assert "Could not resolve from Terraform" in text
    assert "users recover in ~30 s; redundancy is reduced for ~14 min" in text
    assert "**clean withdrawal**" in text and "**silent failure**" in text
    assert "## Change (transition) risks" in text
    assert js.exists()
