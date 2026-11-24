"""Read the current Terraform with python-hcl2 and check / fill facts in the model.

Only the current roots are parsed. The v1 roots that will be rewritten (aws/eks,
azure/aks, global/dns) are not read: their components are modelled as planned.
Nothing here talks to a cloud or to a Terraform backend; it only reads .tf files.
"""
from __future__ import annotations

import re
from pathlib import Path

import hcl2

from .model import REPO_ROOT, Model, parse_tf_entry

PHASE2_ROOTS = [
    "aws/hub",
    "aws/spoke-app",
    "azure/hub",
    "azure/spoke-aks",
    "connectivity/vpn",
    "ops",
]
# Read only to confirm the state bucket exists and is versioned; not a v1 root
EXTRA_ROOTS = ["bootstrap"]
PLANNED_ROOTS = ["aws/eks", "azure/aks", "global/dns"]

_META = ("__is_block__", "__comments__", "__start_line__", "__end_line__")


# ---------------- HCL normalisation ----------------

def _unquote(s):
    if isinstance(s, str) and len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        inner = s[1:-1]
        if "${" not in inner:
            return inner.replace('\\"', '"')
    return s


def normalize(obj):
    """python-hcl2 v8 keeps quotes on labels and string literals; strip them."""
    if isinstance(obj, dict):
        return {_unquote(k): normalize(v) for k, v in obj.items() if k not in _META}
    if isinstance(obj, list):
        return [normalize(v) for v in obj]
    return _unquote(obj)


class Root:
    """One parsed Terraform root."""

    def __init__(self, name: str, path: Path):
        self.name = name
        self.path = path
        self.resources: dict[str, dict] = {}   # "type.name" -> body
        self.variables: dict[str, dict] = {}
        self.locals: dict[str, object] = {}
        self.files: dict[str, str] = {}        # filename -> text
        for tf in sorted(path.glob("*.tf")):
            text = tf.read_text()
            self.files[tf.name] = text
            with open(tf) as fh:
                raw = normalize(hcl2.load(fh))
            for block in raw.get("resource", []):
                for rtype, named in block.items():
                    for rname, body in named.items():
                        self.resources[f"{rtype}.{rname}"] = body
            for block in raw.get("variable", []):
                for vname, body in block.items():
                    self.variables[vname] = body
            for block in raw.get("locals", []):
                self.locals.update(block)

    def source(self, needle: str) -> str:
        """file:line of the first line containing needle (for the report)."""
        for fname, text in self.files.items():
            for i, line in enumerate(text.splitlines(), 1):
                if needle in line:
                    return f"terraform/{self.name}/{fname}:{i}"
        return f"terraform/{self.name}"

    def resource_source(self, address: str) -> str:
        rtype, rname = address.split(".", 1)
        return self.source(f'resource "{rtype}" "{rname}"')

    def template(self, filename: str) -> str | None:
        p = self.path / filename
        return p.read_text() if p.exists() else None


def load_roots(repo: Path = REPO_ROOT) -> dict[str, Root]:
    roots = {}
    for name in PHASE2_ROOTS + EXTRA_ROOTS:
        p = repo / "terraform" / name
        if p.is_dir():
            roots[name] = Root(name, p)
    return roots


# ---------------- simple expression resolver ----------------

class Unresolved(Exception):
    pass


_LIT_LIST = re.compile(r'^\$\{(?:toset\()?\[(.*)\]\)?\}$')


def resolve(expr, root: Root):
    """Resolve literals, var.x defaults, length(var.x), var.x[N], var.x ? a : b, toset([...]).

    Anything else (locals with for-expressions, remote state, resource attributes) raises
    Unresolved with the raw expression, so the report can say what it could not read.
    """
    if not isinstance(expr, str):
        return expr
    if "${" not in expr:
        return expr
    m = re.fullmatch(r"\$\{var\.(\w+)\}", expr)
    if m:
        return _var_default(m.group(1), root)
    m = re.fullmatch(r"\$\{length\(var\.(\w+)\)\}", expr)
    if m:
        return len(_var_default(m.group(1), root))
    m = re.fullmatch(r"\$\{var\.(\w+)\[(\d+)\]\}", expr)
    if m:
        return _var_default(m.group(1), root)[int(m.group(2))]
    m = re.fullmatch(r"\$\{var\.(\w+)\s*\?\s*(.+?)\s*:\s*(.+?)\}", expr)
    if m:
        cond = _var_default(m.group(1), root)
        branch = m.group(2) if cond else m.group(3)
        return resolve("${" + branch + "}", root) if not re.fullmatch(r"-?\d+", branch) else int(branch)
    m = re.fullmatch(r"\$\{local\.(\w+)\}", expr)
    if m and m.group(1) in root.locals and "${" not in str(root.locals[m.group(1)]):
        return root.locals[m.group(1)]
    m = _LIT_LIST.fullmatch(expr)
    if m:
        items = re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))
        return items
    m = re.fullmatch(r"\$\{(-?\d+)\}", expr)
    if m:
        return int(m.group(1))
    raise Unresolved(expr)


def _var_default(name: str, root: Root):
    v = root.variables.get(name)
    if v is None or "default" not in v:
        raise Unresolved(f"var.{name} (no default in terraform/{root.name})")
    d = v["default"]
    if isinstance(d, str) and "${" in d:
        raise Unresolved(f"var.{name} default is an expression: {d}")
    return d


def instance_count(body: dict, root: Root):
    """How many instances a resource block makes: (count, how)."""
    if "count" in body:
        return resolve(body["count"], root), f"count = {body['count']}"
    if "for_each" in body:
        fe = resolve(body["for_each"], root)
        return len(fe), f"for_each = {body['for_each']}"
    return 1, "no count / for_each"


# ---------------- facts ----------------

class Facts:
    def __init__(self):
        self.facts: dict[str, dict] = {}

    def ok(self, key, value, source, detail=""):
        self.facts[key] = {"value": value, "resolved": True, "source": source, "detail": detail}

    def derived(self, key, value, source, detail):
        self.facts[key] = {"value": value, "resolved": True, "derived": True, "source": source, "detail": detail}

    def unresolved(self, key, source, detail, assumed=None):
        self.facts[key] = {"value": assumed, "resolved": False, "source": source, "detail": detail}

    def get(self, key, default=None):
        f = self.facts.get(key)
        return f["value"] if f else default


def _try(facts: Facts, key: str, fn, source: str, detail: str = "", assumed=None):
    try:
        facts.ok(key, fn(), source, detail)
    except (Unresolved, KeyError, IndexError, TypeError) as e:
        facts.unresolved(key, source, f"{detail} could not resolve: {e}".strip(), assumed)


def read_facts(roots: dict[str, Root]) -> Facts:
    f = Facts()

    hub = roots.get("aws/hub")
    if hub:
        fw = hub.resources.get("aws_instance.fw", {})
        src = hub.resource_source("aws_instance.fw")
        _try(f, "aws_fw_count", lambda: instance_count(fw, hub)[0], src, f"aws_instance.fw count = {fw.get('count')}")
        _try(f, "aws_fw_ips", lambda: _var_default("fw_ips", hub), hub.source('variable "fw_ips"'))

        route = hub.resources.get("aws_route.tgw_to_fw", {})
        target = next((k for k in ("network_interface_id", "vpc_endpoint_id", "gateway_id", "transit_gateway_id")
                       if k in route), None)
        f.ok("tgw_to_fw_target", target, hub.resource_source("aws_route.tgw_to_fw"),
             f"aws_route.tgw_to_fw {target} = {route.get(target)}; pinned per AZ" if target == "network_interface_id"
             else f"aws_route.tgw_to_fw uses {target}")
        _try(f, "tgw_to_fw_route_count", lambda: instance_count(route, hub)[0], hub.resource_source("aws_route.tgw_to_fw"))

        att = hub.resources.get("aws_ec2_transit_gateway_vpc_attachment.inspection", {})
        _try(f, "appliance_mode", lambda: resolve(att["appliance_mode_support"], hub),
             hub.source('variable "appliance_mode"'),
             f"aws_ec2_transit_gateway_vpc_attachment.inspection appliance_mode_support = {att.get('appliance_mode_support')}")
        tgw = hub.resources.get("aws_ec2_transit_gateway.tgw", {})
        _try(f, "tgw_vpn_ecmp", lambda: resolve(tgw["vpn_ecmp_support"], hub), hub.resource_source("aws_ec2_transit_gateway.tgw"))
        _try(f, "tgw_default_rt_association", lambda: resolve(tgw["default_route_table_association"], hub),
             hub.resource_source("aws_ec2_transit_gateway.tgw"))
        _try(f, "aws_fw_instance_type", lambda: _var_default("fw_instance_type", hub), hub.source('variable "fw_instance_type"'))

        tpl = hub.template("fw-cloud-init.yaml.tftpl") or ""
        az_fwd = re.findall(r"server=/[^/]+/\$\{azure_fw_ip\}", tpl)
        f.ok("aws_fw_dns_forward_targets_azure", 1 if az_fwd else 0, "terraform/aws/hub/fw-cloud-init.yaml.tftpl",
             f"{len(az_fwd)} Azure zones forwarded to the single ${{azure_fw_ip}}")
        f.ok("aws_fw_stateful", bool(re.search(r"ct state invalid.*drop", tpl)),
             "terraform/aws/hub/fw-cloud-init.yaml.tftpl", "nftables forward chain drops ct state invalid")

    spoke = roots.get("aws/spoke-app")
    if spoke:
        _try(f, "propagate_to_inspection", lambda: _var_default("propagate_to_inspection", spoke),
             spoke.source('variable "propagate_to_inspection"'))
        prop = spoke.resources.get("aws_ec2_transit_gateway_route_table_propagation.app_to_inspection", {})
        _try(f, "app_to_inspection_count", lambda: instance_count(prop, spoke)[0],
             spoke.resource_source("aws_ec2_transit_gateway_route_table_propagation.app_to_inspection"),
             f"count = {prop.get('count')}")
        _try(f, "enable_secondary_cidr", lambda: _var_default("enable_secondary_cidr", spoke),
             spoke.source('variable "enable_secondary_cidr"'))
        ep = spoke.resources.get("aws_vpc_endpoint.s3_interface", {})
        subnets = ep.get("subnet_ids")
        f.ok("s3_interface_endpoint_azs", len(subnets) if isinstance(subnets, list) else None,
             spoke.resource_source("aws_vpc_endpoint.s3_interface"), f"subnet_ids = {subnets}")
        try:
            sec = _var_default("enable_secondary_cidr", spoke)
            cidrs = [_var_default("vpc_cidr", spoke)] + ([_var_default("secondary_cidr", spoke)] if sec else [])
            f.derived("vpn_to_app_cidrs", cidrs, spoke.resource_source("aws_ec2_transit_gateway_route.vpn_to_app"),
                      "local.spoke_cidrs is a concat() expression; evaluated by hand from vpc_cidr, "
                      "secondary_cidr and enable_secondary_cidr defaults")
        except Unresolved as e:
            f.unresolved("vpn_to_app_cidrs", spoke.source("spoke_cidrs"), str(e))
        f.unresolved("app_tgw_attachment_target", spoke.resource_source("aws_ec2_transit_gateway_vpc_attachment.app"),
                     "transit_gateway_id = local.hub.tgw_id comes from terraform_remote_state; assumed to be "
                     "aws_ec2_transit_gateway.tgw in aws/hub", assumed="aws/hub:aws_ec2_transit_gateway.tgw")

    azh = roots.get("azure/hub")
    if azh:
        gw = azh.resources.get("azurerm_virtual_network_gateway.vpngw", {})
        gsrc = azh.resource_source("azurerm_virtual_network_gateway.vpngw")
        _try(f, "azure_active_active", lambda: resolve(gw["active_active"], azh), gsrc)
        _try(f, "azure_vpngw_sku", lambda: resolve(gw["sku"], azh), gsrc)
        pip = azh.resources.get("azurerm_public_ip.vpngw", {})
        _try(f, "azure_vpngw_instances", lambda: instance_count(pip, azh)[0], azh.resource_source("azurerm_public_ip.vpngw"),
             "one public IP / ip_configuration per gateway instance")
        vm = azh.resources.get("azurerm_linux_virtual_machine.fw", {})
        _try(f, "azure_fw_vm_count", lambda: instance_count(vm, azh)[0], azh.resource_source("azurerm_linux_virtual_machine.fw"))
        _try(f, "azure_fw_size", lambda: resolve(vm["size"], azh), azh.source('variable "fw_size"'))
        _try(f, "azure_fw_ip", lambda: _var_default("fw_ip", azh), azh.source('variable "fw_ip"'))

        total = 0
        parts = []
        try:
            for addr, body in azh.resources.items():
                if addr.startswith("azurerm_public_ip."):
                    n = instance_count(body, azh)[0]
                    total += n
                    parts.append(f"{addr} x{n}")
            f.ok("azure_public_ip_count", total, "terraform/azure/hub/main.tf", ", ".join(parts))
        except Unresolved as e:
            f.unresolved("azure_public_ip_count", "terraform/azure/hub/main.tf", str(e))

        size = f.get("azure_fw_size")
        m = re.match(r"Standard_B(\d+)", size or "")
        if m:
            fw_vcpu = int(m.group(1))
            f.derived("azure_bseries_vcpu_used", fw_vcpu + 2, azh.source('variable "fw_size"'),
                      f"firewall {size} = {fw_vcpu} vCPU + planned AKS node Standard_B2als_v2 = 2 vCPU "
                      "(azure/aks not yet in code)")

        tpl = azh.template("fw-cloud-init.yaml.tftpl") or ""
        loops = bool(re.search(r"%\{\s*for ip in aws_fw_ips", tpl))
        try:
            n = len(_var_default("aws_fw_ips", azh))
        except Unresolved:
            n = None
        f.ok("azure_dns_forwards_to_aws_fws", n if loops else 1, "terraform/azure/hub/fw-cloud-init.yaml.tftpl",
             "dnsmasq lists every AWS firewall for cloudbridge.internal" if loops else "single AWS forwarder")
        f.ok("azure_fw_stateful", bool(re.search(r"ct state invalid.*drop", tpl)),
             "terraform/azure/hub/fw-cloud-init.yaml.tftpl", "nftables forward chain drops ct state invalid")
        f.ok("azure_fw_dnat", bool(re.search(r"dnat to", tpl)), "terraform/azure/hub/fw-cloud-init.yaml.tftpl",
             "inbound HTTP is DNATed to the AKS internal LB")

    azs = roots.get("azure/spoke-aks")
    if azs:
        rt = azs.resources.get("azurerm_route_table.spoke", {})
        route = rt.get("route", [{}])
        route = route[0] if isinstance(route, list) and route else route
        nh = route.get("next_hop_in_ip_address") if isinstance(route, dict) else None
        f.unresolved("spoke_udr_next_hop", azs.resource_source("azurerm_route_table.spoke"),
                     f"next_hop_in_ip_address = {nh} comes from terraform_remote_state; assumed equal to "
                     f"azure/hub var.fw_ip = {f.get('azure_fw_ip')}", assumed=f.get("azure_fw_ip"))
        _try(f, "spoke_bgp_propagation", lambda: resolve(rt["bgp_route_propagation_enabled"], azs),
             azs.resource_source("azurerm_route_table.spoke"), "false = VPN routes can't bypass the firewall")
        f.ok("gateway_subnet_udr", "azurerm_route_table.gateway" in azs.resources,
             azs.resource_source("azurerm_route_table.gateway"), "VPN -> spoke also through the firewall")

    vpn = roots.get("connectivity/vpn")
    if vpn:
        conn = vpn.resources.get("aws_vpn_connection.azure", {})
        csrc = vpn.resource_source("aws_vpn_connection.azure")
        try:
            n_conn, how = instance_count(conn, vpn)
            tunnels_per = sum(1 for k in ("tunnel1_inside_cidr", "tunnel2_inside_cidr") if k in conn)
            f.ok("vpn_connections", n_conn, csrc, how)
            f.ok("vpn_tunnels", n_conn * tunnels_per, csrc, f"{n_conn} connections x {tunnels_per} tunnel inside CIDRs")
        except Unresolved as e:
            f.unresolved("vpn_connections", csrc, str(e))
        azc = vpn.resources.get("azurerm_virtual_network_gateway_connection.aws", {})
        try:
            instance_count(azc, vpn)
        except Unresolved:
            n = f.get("vpn_tunnels")
            f.unresolved("azure_tunnel_connections", vpn.resource_source("azurerm_virtual_network_gateway_connection.aws"),
                         f"for_each = {azc.get('for_each')}: local.tunnel_keys is a flatten() for-expression; "
                         f"assumed one per AWS tunnel = {n}", assumed=n)
        f.ok("vpn_static_routes_only", conn.get("static_routes_only"), csrc, "false = BGP")
        f.unresolved("bgp_hold_time", csrc,
                     "BGP timers are not set in Terraform (provider defaults); a silent failure was measured "
                     "2026-11-23 at 22-31 s (modelled as 30 s), a clean withdrawal at ~0 s",
                     assumed="~30 s (measured)")

    boot = roots.get("bootstrap")
    if boot:
        ver = boot.resources.get("aws_s3_bucket_versioning.state", {})
        vc = ver.get("versioning_configuration", [{}])
        vc = vc[0] if isinstance(vc, list) and vc else vc
        f.ok("state_bucket_versioning", (vc or {}).get("status"), boot.resource_source("aws_s3_bucket_versioning.state"))

    for p in PLANNED_ROOTS:
        f.unresolved(f"planned:{p}", f"terraform/{p}",
                     "root not written yet (the v1 version is not parsed); "
                     "components taken from docs/plan.md")
    return f


# ---------------- apply facts to the model ----------------

def apply_facts(model: Model, facts: Facts) -> list[dict]:
    """Change the model where the code decides. Returns a log of checks / overrides."""
    log = []

    def note(fact, effect, status="confirmed"):
        log.append({"fact": fact, "value": facts.get(fact), "status": status, "effect": effect})

    target = facts.get("tgw_to_fw_target")
    hop = model.hops["inspection-fw"]
    want = {"network_interface_id": "pinned", "vpc_endpoint_id": "failover"}.get(target)
    if want:
        if hop["mode"] != want:
            note("tgw_to_fw_target", f"inspection-fw mode {hop['mode']} -> {want}", "overridden")
            hop["mode"] = want
        else:
            note("tgw_to_fw_target", f"inspection-fw mode {want}")
    else:
        note("tgw_to_fw_target", "unknown route target; inspection-fw mode left as designed", "unresolved")

    n_fw = facts.get("aws_fw_count")
    if isinstance(n_fw, int):
        fws = ["fw-a", "fw-b"]
        if n_fw < 2:
            for h in ("inspection-fw", "aws-dns-forwarders"):
                model.hops[h]["members"] = fws[:n_fw]
                if n_fw == 1:
                    model.hops[h]["mode"] = "single"
            for c in fws[n_fw:]:
                model.components[c]["present"] = False
            note("aws_fw_count", f"only {n_fw} firewall(s): hops reduced", "overridden")
        elif n_fw > 2:
            note("aws_fw_count", f"{n_fw} firewalls in code; model has 2 (extra not modelled)", "mismatch")
        else:
            note("aws_fw_count", "2 firewalls (fw-a, fw-b)")

    aa = facts.get("azure_active_active")
    if aa is False:
        model.components["az-vpngw-i1"]["present"] = False
        note("azure_active_active", "instance1 absent: c1 tunnels down", "overridden")
    elif aa is True:
        note("azure_active_active", "2 gateway instances")

    nconn = facts.get("vpn_connections")
    if isinstance(nconn, int) and nconn < 2:
        model.components["aws-vpn-c1"]["present"] = False
        note("vpn_connections", "only c0 exists", "overridden")
    elif nconn is not None:
        note("vpn_connections", f"{nconn} VPN connections, {facts.get('vpn_tunnels')} tunnels")

    am = facts.get("appliance_mode")
    if am is not None:
        on = am == "enable"
        model.components["tgw-appliance-mode"]["present"] = on
        note("appliance_mode", "appliance mode on" if on else
             "appliance mode OFF in code: VPN<->VPC flows unaffected (measured); VPC<->VPC cross-AZ replies would be dropped",
             "confirmed" if on else "overridden")

    prop = facts.get("app_to_inspection_count")
    if prop is not None:
        model.components["tgw-prop-app-to-inspection"]["present"] = prop > 0
        note("app_to_inspection_count", "propagation present" if prop else "propagation ABSENT in code (Test 4 break A)",
             "confirmed" if prop else "overridden")

    n_az = facts.get("azure_fw_vm_count")
    if isinstance(n_az, int):
        note("azure_fw_vm_count", "single Azure firewall VM" if n_az == 1 else f"{n_az} VMs; model has 1",
             "confirmed" if n_az == 1 else "mismatch")

    fwd = facts.get("azure_dns_forwards_to_aws_fws")
    if isinstance(fwd, int):
        if fwd >= 2:
            note("azure_dns_forwards_to_aws_fws", "aws-dns-forwarders failover")
        else:
            model.hops["aws-dns-forwarders"]["members"] = ["fw-a"]
            model.hops["aws-dns-forwarders"]["mode"] = "single"
            note("azure_dns_forwards_to_aws_fws", "only one AWS forwarder listed", "overridden")

    eps = facts.get("s3_interface_endpoint_azs")
    if eps is not None:
        note("s3_interface_endpoint_azs", f"S3 interface endpoint in {eps} AZ(s)")

    return log


def check_addresses(model: Model, roots: dict[str, Root]) -> list[dict]:
    """Every tf address listed for a built component must exist in its root."""
    problems = []
    for c in model.components.values():
        if c["status"] == "planned" or c["layer"] == "external":
            continue
        for entry in c["tf"]:
            layer, addr = parse_tf_entry(entry, c["layer"])
            root = roots.get(layer)
            base = re.sub(r"\[.*\]$", "", addr)
            if root is None:
                problems.append({"component": c["id"], "address": entry, "problem": f"root {layer} not found"})
            elif base not in root.resources:
                problems.append({"component": c["id"], "address": entry, "problem": f"not in terraform/{layer}"})
    return problems


def build(repo: Path = REPO_ROOT, design: Path | None = None):
    """Load design.yaml, read the Terraform, return (model, facts, log, address_problems, roots)."""
    model = Model.load(design) if design else Model.load()
    roots = load_roots(repo)
    facts = read_facts(roots)
    log = apply_facts(model, facts)
    problems = check_addresses(model, roots)
    return model, facts, log, problems, roots
