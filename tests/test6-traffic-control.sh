#!/usr/bin/env bash
# Test 6: Kubernetes traffic control.
#
#   policy        Part A. Runs a flow matrix in both clusters, applies k8s/policies (default deny
#                 in and out of the cloudbridge namespace; allow DNS, frontend -> backend, and the
#                 LB -> frontend), runs the matrix again, and collects the drop evidence: Cilium
#                 drop events on AKS (cilium-dbg monitor, Hubble if enabled) and the VPC CNI
#                 network policy agent's DENY flow logs on EKS (a file on each node).
#   policy-off    removes the policies from both clusters
#   egress-azure  Part B, AKS. On the Azure firewall: block all egress from 10.20.0.0/20 and
#                 record what breaks on the node (API server, image pulls, time sync, node
#                 status); then allow only AKS's required FQDNs (dnsmasq fills an nftables set from
#                 the DNS answers) plus NTP, show it works again, and restore allow-all.
#   egress-aws    Part B, EKS. On fw-a and fw-b: allow only TCP 443 and UDP 123 from the EKS
#                 subnets, record what breaks, show that any site on 443 still works, restore.
#   inbound-asym  Why AKS ingress is DNAT on the firewall: documented check with conntrack and
#                 tcpdump on the firewall seeing both directions of a user request.
#
# Firewall changes are live nftables/dnsmasq edits made with idempotent run-command (Azure) and
# SSM (AWS) scripts. The original config is copied to /var/lib/cloudbridge/egress-backup first,
# an EXIT trap restores it if the script dies, and a reboot also restores it (nothing is
# written to /etc/nftables.conf). Nothing here runs terraform.
# Results go to docs/runs/test6-*.
#
# Usage: ./test6-traffic-control.sh policy|policy-off|egress-azure|egress-aws|inbound-asym
# Env:   BLOCK_SECS=120 (how long AKS egress stays fully blocked; keep it well under 300 s, or
#        pods on the NotReady node start being evicted), CILIUM_EXTRAS=1 (also apply
#        k8s/policies/cilium)
set -euo pipefail
cd "$(dirname "$0")"

EKS="kubectl --context cloudbridge-eks"
AKS="kubectl --context cloudbridge-aks"
AWS="aws --region us-east-2"
RG=cloudbridge-rg
AZFW=cloudbridge-fw
AKS_NAME=cloudbridge-aks
TF=../terraform
OUT=../docs/runs/test6
NSH_IMAGE=nicolaka/netshoot:v0.13
AKS_SRC=10.20.0.0/20
EKS_SRC="10.10.0.0/26, 10.10.0.64/26, 10.10.64.0/18"   # node subnets + custom-networking pod subnets
BLOCK_SECS=${BLOCK_SECS:-120}
mkdir -p ../docs/runs

# ==================== helpers ====================

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
wrap() { printf "bash -s <<'CBEOF'\n%s\n%s\nCBEOF\n" "$1" "$2"; }

runcmd_out() {  # split an az run-command message into stdout / stderr
  awk '/^\[stdout\]/{f=1;next} /^\[stderr\]/{f=0} f' <<<"$1"
  awk '/^\[stderr\]/{f=1;next} f' <<<"$1" | grep -v '^$' | sed "s/^/  [$2 stderr] /" >&2 || true
}
azfw() {  # $1 vars, $2 body: run on the Azure firewall as root. Only the last 4 KB come back.
  runcmd_out "$(az vm run-command invoke -g "$RG" -n "$AZFW" --command-id RunShellScript \
    --scripts "$(wrap "$1" "$2")" --query 'value[0].message' -o tsv)" azfw
}
NRG="" VMSS="" VMID=""
aks_node_init() {
  [ -n "$VMSS" ] && return
  NRG=$(az aks show -g "$RG" -n "$AKS_NAME" --query nodeResourceGroup -o tsv)
  VMSS=$(az vmss list -g "$NRG" --query '[0].name' -o tsv)
  VMID=$(az vmss list-instances -g "$NRG" -n "$VMSS" --query '[0].instanceId' -o tsv)
}
aksnode() {  # $1 vars, $2 body: run on the AKS node through the VM agent (works with egress blocked)
  aks_node_init
  runcmd_out "$(az vmss run-command invoke -g "$NRG" -n "$VMSS" --instance-id "$VMID" --command-id RunShellScript \
    --scripts "$(wrap "$1" "$2")" --query 'value[0].message' -o tsv)" aks-node
}

iid() {
  local id
  id=$($AWS ec2 describe-instances --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -z "$id" ] || [ "$id" = None ]; then echo "no running instance named $1" >&2; return 1; fi
  echo "$id"
}
ssm_send() {  # $1 instance id, $2 vars, $3 body, [$4 timeout s] -> command id
  local params
  params=$(jq -n --arg s "$(wrap "$2" "$3")" --arg t "${4:-600}" '{commands: [$s], executionTimeout: [$t]}')
  $AWS ssm send-command --instance-ids "$1" --document-name AWS-RunShellScript \
    --parameters "$params" --query Command.CommandId --output text
}
ssm_wait() {  # $1 instance id, $2 command id, [$3 max wait s] -> stdout
  local st=Pending end=$(( $(date +%s) + ${3:-900} ))
  while [ "$(date +%s)" -lt "$end" ]; do
    st=$($AWS ssm get-command-invocation --instance-id "$1" --command-id "$2" --query Status --output text 2>/dev/null || echo Pending)
    case "$st" in Pending|InProgress|Delayed) sleep 3 ;; *) break ;; esac
  done
  $AWS ssm get-command-invocation --instance-id "$1" --command-id "$2" --query StandardOutputContent --output text 2>/dev/null || true
  [ "$st" = Success ] || echo "  (ssm on $1: $st)" >&2
}
ssm() {
  local cid
  cid=$(ssm_send "$1" "$2" "$3" "${4:-600}")
  ssm_wait "$1" "$cid" "$(( ${4:-600} + 120 ))"
}

try() {  # run, print the exit code, never abort
  local rc=0
  "$@" 2>&1 || rc=$?
  echo "  -> exit $rc"
}

nsh_manifest() {  # $1 name, $2 namespace, $3 extra label value for app
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $2
  labels: { app: $3 }
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: nsh
      image: $NSH_IMAGE
      command: ["sleep", "infinity"]
EOF
}
nsh_up() {  # $1 kubectl, $2 name, $3 namespace, $4 app label. Reuses a pod that already exists
  $1 -n "$3" get pod "$2" >/dev/null 2>&1 || nsh_manifest "$2" "$3" "$4" | $1 apply -f - >/dev/null
  $1 -n "$3" wait --for=condition=Ready "pod/$2" --timeout=240s >/dev/null
}

alb_host() {
  $EKS -n cloudbridge get ingress frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true
}
fw_public_ip() { terraform -chdir=$TF/azure/hub output -raw fw_public_ip; }

# ==================== Part A: NetworkPolicy ====================

# Python one-liner for the app pods (python:3.12-slim has no curl). Any HTTP answer counts as
# "reached" (a 503 from the frontend still means the connection was allowed).
PYGET='import sys, urllib.request as u, urllib.error as e
try:
    r = u.urlopen(sys.argv[1], timeout=4); print("reached", r.status)
except e.HTTPError as x:
    print("reached", x.code)
except Exception as x:
    print("failed", type(x).__name__, str(x)[:60]); sys.exit(1)'

flow() {  # $1 label, $2 expected-after, then the command: prints one result line
  local label=$1 want=$2 rc=0 out
  shift 2
  out=$("$@" 2>&1 | tail -1 | cut -c1-70) || rc=$?
  [ $rc = 0 ] && res=ALLOWED || res="BLOCKED (exit $rc)"
  printf "  %-44s expect-after: %-8s now: %-18s %s\n" "$label" "$want" "$res" "$out"
}

matrix() {  # $1 kubectl, $2 cloud (aws|azure)
  local K=$1 cloud=$2 ext
  if [ "$cloud" = aws ]; then ext="http://$(alb_host)/health"; else ext="http://$(fw_public_ip)/health"; fi
  flow "frontend -> backend:8080"           allow   $K -n cloudbridge exec deploy/frontend -c app -- python -c "$PYGET" http://backend:8080/
  flow "probe -> backend:8080"              block   $K -n cloudbridge exec cb-probe -- curl -s -o /dev/null -m 4 -w '%{http_code}' http://backend:8080/
  flow "probe DNS (CoreDNS)"                allow   $K -n cloudbridge exec cb-probe -- dig +short +time=3 +tries=1 backend.cloudbridge.svc.cluster.local
  flow "probe -> internet https"            block   $K -n cloudbridge exec cb-probe -- curl -s -o /dev/null -m 4 -w '%{http_code}' https://www.example.com
  flow "backend -> frontend:80"             block   $K -n cloudbridge exec deploy/backend -c app -- python -c "$PYGET" http://frontend:80/live
  flow "frontend -> internet https"         block   $K -n cloudbridge exec deploy/frontend -c app -- python -c "$PYGET" https://www.example.com
  flow "internet -> LB -> frontend /health" allow   curl -s -o /dev/null -m 8 -w '%{http_code}' --fail "$ext"
}

# Read the VPC CNI network policy agent's flow log on every EKS node (enablePolicyEventLogs
# writes DENY/ACCEPT verdicts to this file). A short-lived pod per node mounts it read-only.
eks_policy_logs() {  # $1 regex of IPs to keep
  local n i=0 name
  for n in $($EKS get nodes -o jsonpath='{.items[*].metadata.name}'); do
    i=$((i + 1)); name=cb-npa-log-$i
    $EKS -n default delete pod "$name" --ignore-not-found >/dev/null
    cat <<EOF | $EKS apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: $name, namespace: default }
spec:
  nodeName: $n
  restartPolicy: Never
  tolerations: [{ operator: Exists }]
  containers:
    - name: c
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          f=/npa/network-policy-agent.log
          echo "DENY lines in \$f: \$(grep -c DENY \$f)"
          grep DENY \$f | grep -E '$1' | tail -n 8
      volumeMounts: [{ name: npa, mountPath: /npa, readOnly: true }]
  volumes: [{ name: npa, hostPath: { path: /var/log/aws-routed-eni } }]
EOF
    $EKS -n default wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$name" --timeout=120s >/dev/null 2>&1 || true
    echo "-- node $n"
    $EKS -n default logs "$name" 2>&1 | cut -c1-300 | sed 's/^/   /'
    $EKS -n default delete pod "$name" --wait=false >/dev/null
  done
}

cmd_policy() {
  local out=$OUT-policy.txt tmp cap pod_ips_aws pod_ips_az
  tmp=$(mktemp -d)
  nsh_up "$EKS" cb-probe cloudbridge probe
  nsh_up "$AKS" cb-probe cloudbridge probe
  {
    echo "== Test 6 Part A: NetworkPolicy, $(ts)"
    echo "cb-probe = a netshoot pod in the cloudbridge namespace (app=probe): no policy allows it anything but DNS"
    echo
    echo "== BEFORE (no policies: everything is allowed)"
    echo "-- EKS"; matrix "$EKS" aws
    echo "-- AKS"; matrix "$AKS" azure
    echo
    echo "== Applying k8s/policies/aws to EKS and k8s/policies/azure to AKS"
    $EKS apply -k ../k8s/policies/aws
    $AKS apply -k ../k8s/policies/azure
    if [ -n "${CILIUM_EXTRAS:-}" ] && $AKS get crd ciliumnetworkpolicies.cilium.io >/dev/null 2>&1; then
      $AKS apply -k ../k8s/policies/cilium
    fi
    echo "waiting 20 s for both engines to program the rules"
    sleep 20

    # Cilium drop monitor on the (single) AKS node, running while the AKS matrix runs
    $AKS -n kube-system exec ds/cilium -c cilium-agent -- sh -c \
      'if command -v timeout >/dev/null; then exec timeout 45 cilium-dbg monitor --type drop; else exec cilium-dbg monitor --type drop; fi' \
      > "$tmp/cilium-drop.txt" 2>&1 &
    cap=$!
    ( sleep 50; kill $cap 2>/dev/null ) &   # backstop if the agent image has no timeout
    sleep 3
    echo
    echo "== AFTER"
    echo "-- EKS"; matrix "$EKS" aws
    echo "-- AKS"; matrix "$AKS" azure
    wait $cap || true
    echo
    echo "== Pods still Ready under default-deny (kubelet probes come from the node and are not blocked)"
    $EKS -n cloudbridge get pods -o wide --no-headers | awk '{print "  eks", $1, $2, $3, $6}'
    $AKS -n cloudbridge get pods -o wide --no-headers | awk '{print "  aks", $1, $2, $3, $6}'
    echo
    echo "== Drop evidence, AKS: cilium-dbg monitor --type drop (45 s window)"
    grep -E 'xx drop|Policy denied' "$tmp/cilium-drop.txt" | head -n 12 | cut -c1-220 | sed 's/^/   /' || true
    echo "   drop events captured: $(grep -c 'drop' "$tmp/cilium-drop.txt" || true)"
    echo "-- Hubble (only if enabled on this cluster)"
    $AKS -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --verdict DROPPED --namespace cloudbridge --last 10 2>&1 |
      head -n 12 | cut -c1-220 | sed 's/^/   /' || echo "   hubble not available (needs Advanced Container Networking Services)"
    echo
    echo "== Drop evidence, EKS: network policy agent flow log (DENY verdicts for the probe and app pods)"
    pod_ips_aws=$($EKS -n cloudbridge get pods -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | sed 's/\./\\./g' | paste -sd'|' -)
    eks_policy_logs "$pod_ips_aws"
    echo
    echo "   VPC flow logs will NOT show these: the drop happens in eBPF on the node, after the"
    echo "   security group has already accepted the packet."
    echo
    echo "Policies stay applied. Remove them with: $0 policy-off"
  } 2>&1 | tee "$out"
  rm -rf "$tmp"
  echo "saved: $out"
}

cmd_policy_off() {
  $EKS delete -k ../k8s/policies/aws --ignore-not-found
  $AKS delete -k ../k8s/policies/azure --ignore-not-found
  $AKS delete -k ../k8s/policies/cilium --ignore-not-found 2>/dev/null || true
  $EKS -n cloudbridge delete pod cb-probe --ignore-not-found --wait=false
  $AKS -n cloudbridge delete pod cb-probe --ignore-not-found --wait=false
}

# ==================== Part B: egress, shared firewall script ====================

# Runs on any of the 3 firewalls. Idempotent: every mode can be rerun.
#   MODE=backup   copy the original config once (never overwritten while a backup exists)
#   MODE=block    jump SRC->internet into chain 'egress', which drops everything
#   MODE=allow    same chain: accept the allow4 set (+ ports in PORTS), drop the rest
#   MODE=ports    same chain: accept only PORTS, drop the rest (AWS)
#   MODE=restore  remove jump, chain, set and the dnsmasq egress file; compare with the backup
#   MODE=status   counters and set size
read -r -d '' FW_BODY <<'EOF' || true
BK=/var/lib/cloudbridge/egress-backup
DQ=/etc/dnsmasq.d/cloudbridge-egress.conf
set -e
backup() {
  mkdir -p $BK
  [ -f $BK/nftables.conf ] || cp -a /etc/nftables.conf $BK/nftables.conf
  [ -f $BK/ruleset.nft ] || nft -s list ruleset > $BK/ruleset.nft
  [ -d $BK/dnsmasq.d ] || cp -a /etc/dnsmasq.d $BK/dnsmasq.d
  echo "backup in $BK: $(ls $BK | tr '\n' ' ')"
}
chain() {  # create set + chain, flush the chain, make sure the jump exists exactly once
  backup >/dev/null
  nft list set inet fw allow4 >/dev/null 2>&1 || nft add set inet fw allow4 '{ type ipv4_addr; flags timeout; timeout 3h; }'
  nft list chain inet fw egress >/dev/null 2>&1 || nft add chain inet fw egress
  nft flush chain inet fw egress
  if ! nft list chain inet fw forward | grep -q cb-egress-jump; then
    # index 2 = right after "ct state established,related accept" and "ct state invalid drop"
    nft insert rule inet fw forward index 2 ip saddr "{ $SRC }" ip daddr != 10.0.0.0/8 jump egress comment '"cb-egress-jump"'
  fi
}
deny() { nft add rule inet fw egress limit rate 20/second counter log prefix '"fw-egress-deny "' level info; nft add rule inet fw egress counter drop; }
kill_flows() {  # established flows would keep going through the first rule; cut them
  for s in $(echo "$SRC" | tr ',' ' '); do
    m=$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_network(sys.argv[1]).netmask)' "$s")
    conntrack -D -s "${s%/*}" --mask-src "$m" >/dev/null 2>&1 || true
  done
}
ports() {
  for p in $PORTS; do nft add rule inet fw egress meta l4proto "${p%%/*}" th dport "${p##*/}" counter accept; done
}
case "$MODE" in
  backup) backup ;;
  block) chain; deny; kill_flows; echo "egress from $SRC to the internet: BLOCKED" ;;
  ports) chain; ports; deny; kill_flows; echo "egress from $SRC: only $PORTS" ;;
  allow)
    chain
    nft add rule inet fw egress ip daddr @allow4 counter accept
    ports
    deny
    if dnsmasq --version | grep -qw nftset && ! dnsmasq --version | grep -qw no-nftset; then
      echo "# Test 6: fill inet fw allow4 from DNS answers (removed by the restore)" > $DQ
      echo "nftset=/$(echo $DOMAINS | tr ' ' '/')/4#inet#fw#allow4" >> $DQ
      systemctl restart dnsmasq   # empty cache: the next answers come from upstream and fill the set
      echo "dnsmasq nftset: $(grep -c nftset $DQ) line, $(echo $DOMAINS | wc -w) domains"
    else
      echo "dnsmasq has no nftset support ($(dnsmasq --version | head -1)); static fallback: resolving once"
    fi
    for n in $SEED; do
      for ip in $(dig +short +time=2 +tries=1 @$FWIP "$n" A | grep -E '^[0-9.]+$'); do
        nft add element inet fw allow4 "{ $ip }" 2>/dev/null || true
      done
    done
    echo "allow4 now holds $(nft list set inet fw allow4 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u | wc -l) IPs"
    ;;
  restore)
    while h=$(nft -a list chain inet fw forward | awk '/cb-egress-jump/ {print $NF; exit}'); [ -n "$h" ]; do
      nft delete rule inet fw forward handle "$h"
    done
    nft list chain inet fw egress >/dev/null 2>&1 && nft delete chain inet fw egress
    nft list set inet fw allow4 >/dev/null 2>&1 && nft delete set inet fw allow4
    if [ -f $DQ ]; then rm -f $DQ; systemctl restart dnsmasq; fi
    if [ -f $BK/ruleset.nft ]; then
      diff -r /etc/dnsmasq.d $BK/dnsmasq.d >/dev/null 2>&1 && echo "dnsmasq.d identical to the backup" || echo "dnsmasq.d differs from the backup!"
      if nft -s list ruleset | diff -q - $BK/ruleset.nft >/dev/null; then
        echo "ruleset identical to the backup: RESTORED"
        mv $BK "$BK.done-$(date +%s)"
      else
        echo "ruleset differs from the backup, reloading the original file"
        nft -f $BK/nftables.conf
        nft -s list ruleset | diff - $BK/ruleset.nft | head -20 || true
      fi
    else
      echo "no backup found: nothing was changed by this script"
    fi
    ;;
  status)
    nft list chain inet fw forward | grep -E 'cb-egress|counter' | sed 's/^\s*/  /' | cut -c1-160
    nft list chain inet fw egress 2>/dev/null | grep counter | sed 's/^\s*/  egress: /' | cut -c1-160 || echo "  no egress chain"
    echo "  allow4 IPs: $(nft list set inet fw allow4 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u | wc -l)"
    echo "  fw-egress-deny log lines (last 10 min): $(journalctl -k --since -10min --no-pager | grep -c 'fw-egress-deny ' || true)"
    journalctl -k --since -10min --no-pager | grep 'fw-egress-deny ' | tail -3 | grep -oE 'SRC=[^ ]+ DST=[^ ]+ .*PROTO=[A-Z]+( SPT=[0-9]+ DPT=[0-9]+)?' | sed 's/^/  e.g. /' || true
    ;;
esac
EOF

# ==================== Part B: AKS egress ====================

# AKS's required egress with outboundType userDefinedRouting, from Microsoft's "Outbound
# network and FQDN rules for AKS clusters" (also listed in terraform/azure/aks/main.tf).
# dnsmasq matches subdomains, so "hcp.northcentralus.azmk8s.io" covers the cluster's
# *.hcp... API name and "data.mcr.microsoft.com" covers *.data.mcr.microsoft.com.
AKS_FQDNS="hcp.northcentralus.azmk8s.io mcr.microsoft.com data.mcr.microsoft.com mcr-0001.mcr-msedge.net
management.azure.com login.microsoftonline.com packages.microsoft.com acs-mirror.azureedge.net
packages.aks.azure.com ntp.ubuntu.com"

# What the node can and can't do. Runs through the VM agent, so it works while egress is cut.
read -r -d '' NODE_BODY <<'EOF' || true
code() { curl -s -o /dev/null -m 6 -w '%{http_code}' "$1" 2>/dev/null || true; }
pull() { timeout 45 crictl pull "$1" >/dev/null 2>&1 && echo ok || echo FAIL; }
echo "node time (UTC)       $(date -u +%T)"
echo "API server /healthz   http $(code https://$API/healthz)   (any code = reachable, 000 = cut)"
echo "ACR /v2/              http $(code https://$ACR/v2/)   (401 = reachable)"
echo "pull mcr (pause:3.6)  $(pull mcr.microsoft.com/oss/kubernetes/pause:3.6)"
echo "pull docker.io        $(pull docker.io/library/busybox:1.36)"
echo "other site (bing)     http $(code https://www.bing.com)"
echo "time sync (chrony):"
chronyc -n tracking 2>/dev/null | grep -E 'Reference ID|System time|Leap status' | sed 's/^/  /'
chronyc -n sources 2>/dev/null | tail -n +3 | head -5 | sed 's/^/  /'
echo "kubelet errors talking to the API in the last 2 min: $(journalctl -u kubelet --since -2min --no-pager 2>/dev/null | grep -ciE 'error updating node status|failed to update lease|i/o timeout|context deadline exceeded|connection refused')"
journalctl -u kubelet --since -2min --no-pager 2>/dev/null | grep -iE 'error updating node status|failed to update lease' | tail -1 | cut -c1-200
EOF

node_ready() { $AKS get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status}/{.status.conditions[?(@.type=="Ready")].reason} {end}'; }

AZ_RESTORE_NEEDED=""
az_restore() {
  [ -n "$AZ_RESTORE_NEEDED" ] || return 0
  echo "== RESTORE: allow-all egress on the Azure firewall"
  azfw "MODE=restore; SRC='$AKS_SRC'" "$FW_BODY"
  AZ_RESTORE_NEEDED=""
}

cmd_egress_azure() {
  local out=$OUT-egress-azure.txt api acr fwip vars end
  fwip=$(terraform -chdir=$TF/azure/hub output -raw fw_ip 2>/dev/null || echo 10.20.241.4)
  api=$(az aks show -g "$RG" -n "$AKS_NAME" --query fqdn -o tsv)
  acr=$(terraform -chdir=$TF/azure/aks output -raw acr_login_server)
  vars="API=$api; ACR=$acr"
  nsh_up "$AKS" cb-nsh default cb-nsh
  # Output goes through tee -i (ignores Ctrl-C), so the restore in the EXIT trap still runs
  # and is still logged if you interrupt the test
  exec > >(tee -i "$out") 2>&1
  trap 'az_restore' EXIT
  trap 'exit 130' INT TERM
  echo "== Test 6 Part B, AKS egress through the hub firewall, $(ts)"
  echo "API server $api, ACR $acr, node $(node_ready)"
  echo "-- egress IP seen by the internet from an AKS pod (expect the firewall's public IP $(fw_public_ip)):"
  try $AKS exec cb-nsh -- curl -s -m 6 https://api.ipify.org; echo
  echo
  echo "== 0. Backup of the firewall config"
  azfw "MODE=backup" "$FW_BODY"
  echo
  echo "== 1. Baseline (allow-all)"
  aksnode "$vars" "$NODE_BODY"
  echo
  echo "== 2. BLOCK everything from $AKS_SRC to the internet ($BLOCK_SECS s)"
  AZ_RESTORE_NEEDED=1
  azfw "MODE=block; SRC='$AKS_SRC'" "$FW_BODY"
  end=$(( $(date +%s) + BLOCK_SECS ))
  while [ "$(date +%s)" -lt "$end" ]; do
    echo "  $(date +%H:%M:%S) node: $(node_ready)"
    sleep 20
  done
  echo "-- on the node while blocked"
  aksnode "$vars" "$NODE_BODY"
  echo "-- firewall"
  azfw "MODE=status" "$FW_BODY"
  echo
  echo "== 3. ALLOW only AKS's required FQDNs + $acr + blob.core.windows.net (ACR Basic layers) + NTP"
  azfw "MODE=allow; SRC='$AKS_SRC'; PORTS='udp/123'; FWIP=$fwip; DOMAINS='$(echo $AKS_FQDNS) $acr blob.core.windows.net'; SEED='$api mcr.microsoft.com $acr management.azure.com login.microsoftonline.com packages.microsoft.com acs-mirror.azureedge.net packages.aks.azure.com ntp.ubuntu.com'" "$FW_BODY"
  end=$(( $(date +%s) + 300 ))
  until node_ready | grep -q '=True/'; do
    [ "$(date +%s)" -lt "$end" ] || { echo "  node still not Ready after 5 min"; break; }
    echo "  $(date +%H:%M:%S) node: $(node_ready)"
    sleep 15
  done
  echo "  $(date +%H:%M:%S) node: $(node_ready)"
  echo "-- on the node with the allowlist"
  aksnode "$vars" "$NODE_BODY"
  echo "-- Kubernetes view: a pod from ACR (pull Always) and one from Docker Hub"
  $AKS -n default delete pod cb-pull-acr cb-pull-hub --ignore-not-found --wait=false >/dev/null
  $AKS -n default run cb-pull-acr --image="$acr/cloudbridge-app:${TAG:-v1}" --image-pull-policy=Always --env=ROLE=backend >/dev/null
  $AKS -n default run cb-pull-hub --image=docker.io/library/busybox:1.36 --image-pull-policy=Always --command -- sleep 600 >/dev/null
  sleep 60
  $AKS -n default get pods cb-pull-acr cb-pull-hub -o custom-columns='POD:.metadata.name,PHASE:.status.phase,STATE:.status.containerStatuses[0].state.waiting.reason,IMAGE:.spec.containers[0].image'
  echo "   expect cb-pull-acr Running, cb-pull-hub ErrImagePull/ImagePullBackOff (docker.io is not on the list)"
  echo "-- firewall: rule counters, allow4 size, recent denies"
  azfw "MODE=status" "$FW_BODY"
  echo
  az_restore
  echo "-- after restore"
  aksnode "$vars" "$NODE_BODY"
  $AKS -n default delete pod cb-pull-acr cb-pull-hub --ignore-not-found --wait=false >/dev/null
  trap - EXIT
  echo "saved: $out"
}

# ==================== Part B: EKS egress ====================

AWS_RESTORE_NEEDED=""
aws_restore() {
  [ -n "$AWS_RESTORE_NEEDED" ] || return 0
  local f
  for f in cloudbridge-fw-a cloudbridge-fw-b; do
    echo "== RESTORE: allow-all egress on $f"
    ssm "$(iid $f)" "MODE=restore; SRC='$EKS_SRC'" "$FW_BODY" 120
  done
  AWS_RESTORE_NEEDED=""
}

eks_probe() {  # what an EKS pod can reach
  local X="$EKS exec cb-nsh --"
  echo "-- egress IP (expect fw-a or fw-b's public IP: $FW_EIPS)"
  try $X curl -s -m 6 https://checkip.amazonaws.com
  echo "-- https://www.example.com (443)";            try $X curl -s -o /dev/null -m 6 -w '%{http_code}\n' https://www.example.com
  echo "-- https://www.wikipedia.org (443, any site)"; try $X curl -s -o /dev/null -m 6 -w '%{http_code}\n' https://www.wikipedia.org
  echo "-- http://example.com (80)";                  try $X curl -s -o /dev/null -m 6 -w '%{http_code}\n' http://example.com
  echo "-- ping 1.1.1.1 (ICMP)";                      try $X ping -c 2 -W 2 1.1.1.1
  echo "-- DNS to a public resolver (udp 53)";        try $X dig +short +time=3 +tries=1 @1.1.1.1 example.com
  echo "-- github.com:22 (ssh, git over ssh)";        try $X nc -zv -w 4 github.com 22
  echo "-- NTP time.google.com udp 123 (48 = reply)"; try $X sh -c "printf '\\033%047d' 0 | nc -u -w 3 time.google.com 123 | wc -c"
  echo "-- in-VPC DNS (VPC resolver, never via the firewall)"; try $X dig +short +time=3 +tries=1 amazon.com
}

cmd_egress_aws() {
  local out=$OUT-egress-aws.txt fwa fwb
  fwa=$(iid cloudbridge-fw-a); fwb=$(iid cloudbridge-fw-b)
  FW_EIPS=$($AWS ec2 describe-instances --instance-ids "$fwa" "$fwb" --query 'Reservations[].Instances[].PublicIpAddress' --output text | tr '\t' ' ')
  nsh_up "$EKS" cb-nsh default cb-nsh
  exec > >(tee -i "$out") 2>&1   # see cmd_egress_azure
  trap 'aws_restore' EXIT
  trap 'exit 130' INT TERM
  echo "== Test 6 Part B, EKS egress through fw-a / fw-b, $(ts)"
  echo "EKS sources: $EKS_SRC"
  echo
  echo "== 1. Baseline (allow-all)"
  eks_probe
  echo
  echo "== 2. Port-based control: only TCP 443 and UDP 123 from the EKS subnets"
  AWS_RESTORE_NEEDED=1
  for f in "fw-a $fwa" "fw-b $fwb"; do
    set -- $f
    echo "-- $1"
    ssm "$2" "MODE=ports; SRC='$EKS_SRC'; PORTS='tcp/443 udp/123'" "$FW_BODY" 120
  done
  sleep 5
  eks_probe
  echo
  echo "-- Kubernetes still works: image pulls are HTTPS (ECR API/DKR on 443, layers via the S3 gateway endpoint)"
  $EKS -n default delete pod cb-pull-hub --ignore-not-found --wait=false >/dev/null
  $EKS -n default run cb-pull-hub --image=docker.io/library/busybox:1.36 --image-pull-policy=Always --command -- sleep 600 >/dev/null
  sleep 40
  $EKS -n default get pod cb-pull-hub -o custom-columns='POD:.metadata.name,PHASE:.status.phase,WAITING:.status.containerStatuses[0].state.waiting.reason'
  $EKS get nodes -o custom-columns='NODE:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'
  echo
  echo "-- firewall counters and denied flows"
  for f in "fw-a $fwa" "fw-b $fwb"; do
    set -- $f
    echo "-- $1"
    ssm "$2" "MODE=status" "$FW_BODY" 120
  done
  cat <<'TXT'

What this shows:
  * Port rules stop plain HTTP, ICMP, public DNS and SSH, but anything on 443 still gets out:
  wikipedia.org works exactly like a required endpoint, and so would a tunnel, a DNS-over-HTTPS
  resolver or a paste site. A port says nothing about the destination.
  * Nothing on the EKS side broke: DNS uses the VPC resolver (10.10.0.2), time uses the Amazon
  Time Sync Service (169.254.169.123), the API server is reached on its private endpoint, and
  image pulls are HTTPS. Neither DNS nor NTP touches the firewall.
  * Production does destination-based control instead:
    - AWS Network Firewall stateful domain-list rules (allowlist on the TLS SNI / HTTP Host),
      with TLS inspection if the SNI can't be trusted, or an explicit proxy;
    - VPC interface endpoints (ECR api/dkr, STS, EC2, logs ...) and the S3 gateway endpoint,
      so AWS API traffic never needs the internet path at all.
  The Azure test does the FQDN version with dnsmasq + nftables sets: allow by the name that
  was resolved, not by port.
TXT
  echo
  aws_restore
  echo "-- after restore"
  try $EKS exec cb-nsh -- curl -s -o /dev/null -m 6 -w '%{http_code}\n' http://example.com
  $EKS -n default delete pod cb-pull-hub --ignore-not-found --wait=false >/dev/null
  trap - EXIT
  echo "saved: $out"
}

# ==================== inbound asymmetric routing ====================

read -r -d '' ASYM_START <<'EOF' || true
rm -f /var/tmp/cb-asym.*
setsid nohup timeout 60 tcpdump -nn -l -i eth0 -c 40 "host $CLIENT and tcp" > /var/tmp/cb-asym.tcpdump 2>&1 < /dev/null &
setsid nohup sh -c "for i in \$(seq 1 25); do conntrack -L -p tcp --orig-src $CLIENT 2>/dev/null; sleep 2; done" > /var/tmp/cb-asym.ct 2>&1 < /dev/null &
echo "capture started for $CLIENT"
EOF
read -r -d '' ASYM_READ <<'EOF' || true
sleep 3
echo "-- tcpdump on the firewall NIC, host $CLIENT (one request = 4 legs: in, DNAT out, reply in, reply out)"
head -n 16 /var/tmp/cb-asym.tcpdump | cut -c1-150
echo "-- conntrack entries for $CLIENT (original direction, then reply direction)"
sed -E 's/ +/ /g' /var/tmp/cb-asym.ct | sort -u -t' ' -k5,8 | head -n 6 | cut -c1-230
echo "   [ASSURED] = this firewall saw packets in both directions"
echo "-- nft counters"
nft list chain ip nat prerouting | grep dnat | sed 's/^\s*/  /'
nft list chain inet fw forward | grep -E 'ct status dnat|invalid' | sed 's/^\s*/  /'
EOF

cmd_inbound_asym() {
  local out=$OUT-inbound-asym.txt pub client i
  pub=$(fw_public_ip)
  client=$(curl -s -m 6 https://checkip.amazonaws.com)
  {
    echo "== Test 6 inbound: why AKS ingress is DNAT on the firewall, $(ts)"
    cat <<'TXT'
The problem (documented by Microsoft for AKS with outboundType userDefinedRouting):
  A public LoadBalancer Service puts a public IP on the Azure LB in front of the nodes. A user's
  SYN arrives at the node straight from that LB, never touching the firewall. The node's reply
  (SYN-ACK to the user's internet IP) follows the subnet's UDR 0.0.0.0/0 -> firewall. The
  firewall never saw the SYN: conntrack marks the SYN-ACK INVALID and nftables drops it
  (fw-invalid). Even a stateless firewall would SNAT it to its own public IP, and the user
  would get a reply from the wrong address and reset it. Result: the LB IP never answers.
The fix used here: no public IP on AKS at all. Users hit the firewall's public IP; the
firewall DNATs to the internal LB 10.20.4.10, so the request and the reply both pass through
it and conntrack un-DNATs the reply. Same path in, same path out.
Demonstrating the broken case needs a 4th public IP, and the subscription allows 3 (2 VPN
gateway + firewall), so this is a documented check of the working path instead.
TXT
    echo
    echo "firewall public IP $pub, this client $client"
    azfw "CLIENT=$client" "$ASYM_START"
    for i in 1 2 3 4 5; do
      printf "  curl %d: " "$i"
      curl -s -o /dev/null -m 8 -w 'http %{http_code} in %{time_total}s\n' "http://$pub/health" || echo "failed"
      sleep 1
    done
    azfw "CLIENT=$client" "$ASYM_READ"
  } 2>&1 | tee "$out"
  echo "saved: $out"
}

case "${1:-}" in
  policy)       cmd_policy ;;
  policy-off)   cmd_policy_off ;;
  egress-azure) cmd_egress_azure ;;
  egress-aws)   cmd_egress_aws ;;
  inbound-asym) cmd_inbound_asym ;;
  *) echo "usage: $0 policy|policy-off|egress-azure|egress-aws|inbound-asym" >&2; exit 1 ;;
esac
