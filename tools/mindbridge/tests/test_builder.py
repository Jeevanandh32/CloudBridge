"""The builder reads the real Terraform and the model reflects it."""
from mindbridge.builder import Unresolved, load_roots, normalize, resolve


def fact(built, key):
    return built[1].facts[key]


def test_aws_firewalls_from_code(built):
    assert fact(built, "aws_fw_count")["value"] == 2
    assert fact(built, "aws_fw_ips")["value"] == ["10.10.240.40", "10.10.240.56"]


def test_tgw_route_pinned_to_eni(built):
    model = built[0]
    assert fact(built, "tgw_to_fw_target")["value"] == "network_interface_id"
    assert model.hops["inspection-fw"]["mode"] == "pinned"


def test_vpn_shape(built):
    assert fact(built, "azure_active_active")["value"] is True
    assert fact(built, "vpn_connections")["value"] == 2
    assert fact(built, "vpn_tunnels")["value"] == 4
    assert fact(built, "azure_vpngw_instances")["value"] == 2


def test_single_azure_firewall_and_quota(built):
    assert fact(built, "azure_fw_vm_count")["value"] == 1
    assert fact(built, "azure_public_ip_count")["value"] == 3
    assert fact(built, "azure_bseries_vcpu_used")["value"] == 4


def test_test4_toggle_defaults(built):
    model = built[0]
    assert fact(built, "appliance_mode")["value"] == "enable"
    assert fact(built, "propagate_to_inspection")["value"] is True
    assert fact(built, "enable_secondary_cidr")["value"] is False
    assert model.components["tgw-appliance-mode"]["present"]
    assert model.components["tgw-prop-app-to-inspection"]["present"]


def test_unresolvable_facts_are_reported_not_guessed(built):
    unresolved = {k for k, v in built[1].facts.items() if not v["resolved"]}
    assert "spoke_udr_next_hop" in unresolved          # remote state
    assert "bgp_hold_time" in unresolved                # not in Terraform (measured ~30 s instead)
    assert {"planned:aws/eks", "planned:azure/aks", "planned:global/dns"} <= unresolved


def test_every_model_address_exists_in_code(built):
    assert built[3] == []


def test_resolver_refuses_what_it_cannot_read():
    roots = load_roots()
    hub = roots["aws/hub"]
    assert resolve("${length(var.azs)}", hub) == 2
    assert resolve("${var.fw_ips[1]}", hub) == "10.10.240.56"
    try:
        resolve("${aws_instance.fw[0].primary_network_interface_id}", hub)
    except Unresolved:
        pass
    else:
        raise AssertionError("resource attribute should be unresolved")


def test_normalize_strips_hcl2_quotes():
    assert normalize({'"a"': {'"b"': '"x"', "__is_block__": True}}) == {"a": {"b": "x"}}


def test_toggles_follow_the_code(built, tmp_path):
    """If appliance mode were off in code, the model sees it absent. VPN<->VPC flows stay OK
    (measured 2026-11-23, Test 4 break B); only VPC<->VPC cross-AZ flows would degrade."""
    import shutil

    from mindbridge.builder import build

    repo = tmp_path / "repo"
    for name in ("aws/hub", "aws/spoke-app", "azure/hub", "azure/spoke-aks", "connectivity/vpn", "ops", "bootstrap"):
        shutil.copytree(built[4][name].path, repo / "terraform" / name,
                        ignore=shutil.ignore_patterns("*.tfvars", "*.tfstate*", ".terraform*"))
    main = repo / "terraform/aws/hub/main.tf"
    text = main.read_text().replace('default     = "enable"', 'default     = "disable"', 1)
    main.write_text(text)
    model, facts, *_ = build(repo)
    assert facts.facts["appliance_mode"]["value"] == "disable"
    assert not model.components["tgw-appliance-mode"]["present"]
    base = model.eval_all(model.baseline_removed())
    assert base["azure-to-aws"].status == "ok"
    assert base["aws-egress"].status == "ok"
