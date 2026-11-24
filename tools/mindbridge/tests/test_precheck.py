"""Each fixture plan gives the expected verdict."""
import json

import pytest

from mindbridge.precheck import classify, load_plan, load_rules, pattern_match, run

from .conftest import FIXTURES

CASES = {
    # fixture: (verdict, layer, {flow: (scenario, status)})
    "break-a-propagation.json": ("block", "aws/spoke-app", {"azure-to-aws": ("after_apply", "broken")}),
    # appliance mode: blocked as a transition risk; the end state costs VPN<->VPC flows nothing
    "break-b-appliance-mode.json": ("block", "aws/hub", {}),
    "appliance-mode-enable.json": ("block", "aws/hub", {}),
    "break-a-restore.json": ("pass", "aws/spoke-app", {}),
    "fw-a-replace.json": ("block", "aws/hub", {"aws-egress": ("during_apply", "degraded"),
                                               "azure-to-aws": ("during_apply", "degraded")}),
    "fw-both-replace-userdata.json": ("block", "aws/hub", {"aws-egress": ("during_apply", "broken"),
                                                           "azure-to-aws": ("during_apply", "broken")}),
    # a connection replacement is a clean BGP withdrawal: no packet loss, reduced redundancy
    "vpn-c0-replace.json": ("pass", "connectivity/vpn", {}),
    "active-active-false.json": ("block", "azure/hub", {"azure-to-aws": ("after_apply", "degraded")}),
    "safe-tags-only.json": ("pass", "aws/hub", {}),
    "s3-endpoint-replace.json": ("pass", "aws/spoke-app", {"azure-to-s3": ("during_apply", "broken")}),
    # Session 2 (aws/eks is still a planned root for the builder, so no layer is inferred)
    "prefix-only.json": ("block", None, {}),
    "prefix-custom.json": ("pass", None, {}),
    "sg-rule-multi-cidr.json": ("block", None, {}),
}


@pytest.fixture(scope="module")
def rules():
    return load_rules()


def _run(built, rules, name, **kw):
    model, _, _, _, roots = built
    return run(load_plan(FIXTURES / name), model, roots, rules, **kw)


@pytest.mark.parametrize("name", sorted(CASES))
def test_fixture_verdict(built, rules, name):
    verdict, layer, expect = CASES[name]
    res = _run(built, rules, name)
    assert res["verdict"] == verdict
    assert res["exit_code"] == (2 if verdict == "block" else 0)
    assert res["layer"] == layer
    for fid, (scen, status) in expect.items():
        row = next(r for r in res["impact"][scen] if r["flow"] == fid)
        assert row["status"] == status, (fid, scen)


def test_break_a_is_persistent_and_manual(built, rules):
    res = _run(built, rules, "break-a-propagation.json")
    row = next(r for r in res["impact"]["after_apply"] if r["flow"] == "azure-to-aws")
    assert row["recovery"] == "manual"
    assert res["changes"][0]["rule"] == "test4-break-a-propagation-removed"


def test_break_a_notes_route_convergence(built, rules):
    res = _run(built, rules, "break-a-propagation.json")
    conv = res["convergence"]
    assert [c["action"] for c in conv] == ["delete"]
    assert conv[0]["window_s"] == 5
    assert "14-20 %" in conv[0]["message"] and "87-95 %" in conv[0]["message"]


def test_break_a_restore_passes_with_convergence_window(built, rules):
    res = _run(built, rules, "break-a-restore.json")
    assert res["verdict"] == "pass" and res["changes"] == []
    assert [c["action"] for c in res["convergence"]] == ["create"]
    from mindbridge.precheck import to_text
    assert "convergence window" in to_text(res)


@pytest.mark.parametrize("name,change", [("break-b-appliance-mode.json", ["enable", "disable"]),
                                         ("appliance-mode-enable.json", ["disable", "enable"])])
def test_appliance_mode_change_is_a_transition_risk_either_way(built, rules, name, change):
    from mindbridge.precheck import to_text

    res = _run(built, rules, name)
    assert res["verdict"] == "block" and res["exit_code"] == 2
    assert res["blocking"] == [{"scenario": "transition", "flow": None, "transition": "appliance-mode-transition"}]
    t = res["transitions"][0]
    assert t["change"] == change and t["window_s"] == 840
    assert "maintenance window" in t["message"].lower()
    assert "22-40 %" in t["message"] and "~14 min" in t["message"]
    # the end state: VPN<->VPC flows were measured unaffected with appliance mode off
    assert res["impact"]["after_apply"] == [] and res["impact"]["during_apply"] == []
    assert "Transition risk" in to_text(res)


def test_single_firewall_replace_recovers_at_end_of_apply(built, rules):
    res = _run(built, rules, "fw-a-replace.json")
    assert res["impact"]["after_apply"] == []
    row = next(r for r in res["impact"]["during_apply"] if r["flow"] == "aws-egress")
    assert row["impact_pct"] == 50.0 and row["recovery"] == "end of apply"


def test_vpn_replace_is_clean_and_reports_both_modes(built, rules):
    from mindbridge.precheck import to_text

    res = _run(built, rules, "vpn-c0-replace.json")
    assert res["impact"]["during_apply"] == [] and res["impact"]["after_apply"] == []
    red = {d["flow"]: d for d in res["redundancy"]["during_apply"]}
    assert red["azure-to-aws"]["redundancy_lost_pct"] == 50.0
    bm = res["bgp_failure_modes"]["during_apply"]
    assert bm["expected"] == "clean"
    assert all(f["status"] == "ok" for f in bm["modes"]["clean"]["flows"])
    silent = {f["flow"]: f for f in bm["modes"]["silent"]["flows"]}
    assert silent["azure-to-aws"]["status"] == "degraded" and silent["azure-to-aws"]["impact_pct"] == 50.0
    assert silent["azure-to-aws"]["recovery_s"] == 30
    text = to_text(res)
    assert "[expected] clean withdrawal" in text and "[if instead] silent failure" in text


def test_gateway_instance_loss_is_silent(built, rules):
    res = _run(built, rules, "active-active-false.json")
    assert res["bgp_failure_modes"]["after_apply"]["expected"] == "silent"
    row = next(r for r in res["impact"]["after_apply"] if r["flow"] == "azure-to-aws")
    assert row["recovery_s"] == 30
    # a config change does not rebuild by itself: no measured window, redundancy stays reduced
    assert row["redundancy_s"] is None and row["redundancy_lost_pct"] == 50.0


def test_active_active_false_is_persistent(built, rules):
    res = _run(built, rules, "active-active-false.json")
    assert res["removed"]["persistent"] == ["az-vpngw-i1"]


def test_threshold_override(built, rules):
    res = _run(built, rules, "s3-endpoint-replace.json", threshold=2)
    assert res["verdict"] == "block"


def test_helpers():
    assert classify(["delete", "create"]) == "replace"
    assert classify(["create", "delete"]) == "replace"
    assert classify(["no-op"]) == "no-op"
    assert pattern_match("aws_instance.fw[*]", "aws_instance.fw[1]")
    assert pattern_match('aws_vpn_connection.azure[*]', 'aws_vpn_connection.azure["c0"]')
    assert pattern_match("aws_instance.fw", "aws_instance.fw[0]")
    assert not pattern_match("aws_instance.fw[*]", "aws_instance.fwx[0]")



# ---------------------------------------------------------------- Session 2: node rolls, duplicate rules

NODE_ROLL = "all nodes replaced one at a time; workloads move; a drain can stall"


def test_prefix_only_is_a_node_roll_and_blocks(built, rules):
    from mindbridge.precheck import to_text

    res = _run(built, rules, "prefix-only.json")
    nr = res["node_roll"]
    assert NODE_ROLL in nr["message"]
    assert {h["address"].split(".")[0] for h in nr["addresses"]} == {"aws_eks_addon", "aws_launch_template",
                                                                     "aws_eks_node_group"}
    assert nr["pod_ip_mode"] == {"before": "secondary-ip", "after": "prefix", "source": "addon"}
    pc = nr["prefix_check"]
    assert pc["id"] == "prefix-delegation-in-node-subnets" and pc["blocks"]
    assert "pods take /28s from the node subnets; check free aligned /28s first" in pc["message"]
    assert "PodEvictionFailure" in pc["message"] and "34-49 free IPs" in pc["message"]
    assert res["blocking"] == [{"scenario": "node-roll", "flow": None, "hazard": "prefix-delegation-in-node-subnets"}]
    # covered changes are not listed as "no rule, treated as safe"
    assert res["changes_without_rule"] == [] and res["unmapped_changes"] == []
    text = to_text(res)
    assert "Node roll:" in text and "BLOCK [prefix-delegation-in-node-subnets]" in text


def test_prefix_with_custom_networking_warns_only(built, rules):
    from mindbridge.precheck import to_text

    res = _run(built, rules, "prefix-custom.json")
    nr = res["node_roll"]
    assert NODE_ROLL in nr["message"]
    assert nr["pod_ip_mode"]["before"] == "prefix" and nr["pod_ip_mode"]["after"] == "prefix-custom-net"
    assert nr["prefix_check"]["id"] == "prefix-delegation-in-pod-subnets" and not nr["prefix_check"]["blocks"]
    assert res["verdict"] == "pass" and res["exit_code"] == 0
    assert "WARNING [prefix-delegation-in-pod-subnets]" in to_text(res)


def test_secondary_ip_straight_to_prefix_custom_warns(built, rules):
    """Both switches in one apply: pods never take /28s from the node subnets."""
    import copy

    model, _, _, _, roots = built
    plan = copy.deepcopy(load_plan(FIXTURES / "prefix-custom.json"))
    addon = next(rc for rc in plan["resource_changes"] if rc["type"] == "aws_eks_addon")
    before = json.loads(addon["change"]["before"]["configuration_values"])
    before["env"].update(ENABLE_PREFIX_DELEGATION="false")
    addon["change"]["before"]["configuration_values"] = json.dumps(before)
    res = run(plan, model, roots, rules)
    assert res["node_roll"]["pod_ip_mode"]["before"] == "secondary-ip"
    assert res["node_roll"]["prefix_check"]["id"] == "prefix-delegation-in-pod-subnets"
    assert res["verdict"] == "pass"


def test_node_group_change_alone_is_a_node_roll(built, rules):
    """No add-on in the plan (e.g. an instance-type change): a roll, no prefix check."""
    import copy

    model, _, _, _, roots = built
    plan = copy.deepcopy(load_plan(FIXTURES / "prefix-only.json"))
    plan["resource_changes"] = [rc for rc in plan["resource_changes"] if rc["type"] == "aws_eks_node_group"]
    ng = plan["resource_changes"][0]["change"]
    ng["after"]["labels"] = ng["before"]["labels"]
    ng["after"]["instance_types"] = ["t3.large"]
    res = run(plan, model, roots, rules)
    assert NODE_ROLL in res["node_roll"]["message"] and res["node_roll"]["prefix_check"] is None
    assert res["verdict"] == "pass"


def test_unrelated_addon_change_is_not_a_node_roll(built, rules):
    import copy

    model, _, _, _, roots = built
    plan = copy.deepcopy(load_plan(FIXTURES / "prefix-only.json"))
    addon = next(rc for rc in plan["resource_changes"] if rc["type"] == "aws_eks_addon")
    addon["change"]["after"]["configuration_values"] = addon["change"]["before"]["configuration_values"]
    addon["change"]["after"]["addon_version"] = "v1.20.5-eksbuild.1"
    plan["resource_changes"] = [addon]
    res = run(plan, model, roots, rules)
    assert res["node_roll"] is None


def test_multi_cidr_sg_rule_replace_is_a_duplicate_hazard(built, rules):
    from mindbridge.precheck import to_text

    res = _run(built, rules, "sg-rule-multi-cidr.json")
    h = res["hazards"][0]
    assert h["id"] == "sg-rule-multi-cidr-replace" and h["action"] == "replace"
    assert h["kept"] == ["10.10.0.0/20"] and h["added"] == ["10.10.64.0/18"]
    assert ("replace of a multi-cidr rule: aws rejects the new rule as a duplicate (invalidpermission.duplicate); "
            "use one rule per cidr") in h["message"].lower()
    assert res["blocking"] == [{"scenario": "hazard", "flow": None, "hazard": "sg-rule-multi-cidr-replace",
                                "address": 'aws_security_group_rule.node["vpc"]'}]
    assert "Hazard [sg-rule-multi-cidr-replace]" in to_text(res)


def test_single_cidr_rule_replace_is_not_a_hazard(built, rules):
    import copy

    model, _, _, _, roots = built
    plan = copy.deepcopy(load_plan(FIXTURES / "sg-rule-multi-cidr.json"))
    ch = plan["resource_changes"][0]["change"]
    ch["after"]["cidr_blocks"] = ["10.10.64.0/18"]          # swapped, nothing kept
    assert run(plan, model, roots, rules)["hazards"] == []
