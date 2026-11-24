#!/usr/bin/env bash
# Test 5: pod networking across clouds.
# EKS pods get real VPC IPs (VPC CNI); AKS pods get overlay IPs (Azure CNI Overlay + Cilium,
# 10.244.0.0/16) that are SNATed to the node IP (10.20.0.x) when they leave the cluster.
#
#   capacity [label]  scale a pause deployment on EKS in steps; per step record free IPs per
#                     subnet (AvailableIpAddressCount), pods per node, ENIs/prefixes per node,
#                     and the first stuck pod with its event reason. With default settings the
#                     per-node limit (max-pods 17 on t3.medium, set by ENIs x IPs) hits first.
#   prefix            prints the terraform command for enable_prefix_delegation=true, waits for
#                     the nodes to roll (automatic, new launch template), reruns capacity:
#                     max-pods goes to 110 and the limit moves to the /26 node subnets, which
#                     have only 4 aligned /28 prefixes each.
#   custom            prints the commands for aws/spoke-app enable_secondary_cidr=true, the aws/eks
#                     re-apply, applies the ENIConfigs, prints enable_custom_networking=true,
#                     waits for the nodes to roll, reruns capacity: pods in 10.10.64.0/18.
#   restore           prints the commands that put EKS back to default pod networking
#   xcloud            netshoot pods in both clusters:
#                       AKS pod -> EKS pod IP direct         (works: pod IPs are VPC IPs)
#                       EKS pod -> AKS pod IP                (fails: overlay IPs aren't routed)
#                       EKS pod -> AKS service via ILB 10.20.4.10 (works)
#                     with tcpdump on the far side of each, showing the source IP that arrives
#   private           cross-cloud DNS from pods and the private-access checks: EKS pod reads the
#                     Azure blob via the Private Endpoint, AKS pod reads S3 via the interface
#                     endpoint
#
# The script never runs terraform: it prints the exact command, you run it in another terminal,
# then press Enter. It does change the clusters (a pause deployment, netshoot pods, ENIConfigs).
# Results go to docs/runs/test5-*.
#
# Usage: ./test5-pod-networking.sh capacity [label]|prefix|custom|restore|xcloud|private
# Env:   STEPS="10 20 ..." (total pause replicas per step), SETTLE=60 (s per step max),
#        KEEP=1 (leave the pause pods running at the end)
set -euo pipefail
cd "$(dirname "$0")"

EKS="kubectl --context cloudbridge-eks"
AKS="kubectl --context cloudbridge-aks"
AWS="aws --region us-east-2"
TF=../terraform
OUT=../docs/runs/test5
NS=cb-capacity
STEPS=${STEPS:-"10 20 30 40 50 60 80 100 120 150 180 220"}
SETTLE=${SETTLE:-60}
NODES_EXPECTED=2
NSH_IMAGE=nicolaka/netshoot:v0.13
ILB_IP=10.20.4.10
mkdir -p ../docs/runs

# ==================== helpers ====================

pause() {  # print the command the user runs, wait for Enter
  echo
  echo "---------------------------------------------------------------------------"
  echo "YOU RUN (another terminal, from the repo root):"
  echo
  echo "$1" | sed 's/^/  /'
  echo
  echo "---------------------------------------------------------------------------"
  read -r -p "Press Enter once the apply has finished... " _
}

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

nodes_table() {
  $EKS get nodes -L topology.kubernetes.io/zone,cloudbridge.io/pod-ip-mode \
    -o custom-columns='NODE:.metadata.name,IP:.status.addresses[?(@.type=="InternalIP")].address,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,MODE:.metadata.labels.cloudbridge\.io/pod-ip-mode,MAX_PODS:.status.capacity.pods,READY:.status.conditions[?(@.type=="Ready")].status'
}

subnets_table() {  # name cidr free
  $AWS ec2 describe-subnets --filters "Name=tag:Name,Values=cloudbridge-app-node-*,cloudbridge-app-pod-*" \
    --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,CidrBlock,AvailableIpAddressCount]' --output text | sort
}

enis_per_node() {  # ENIs, secondary IPs and /28 prefixes attached to each EKS node
  local id name
  $EKS get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.spec.providerID}{"\n"}{end}' |
    while read -r name id; do
      id=${id##*/}
      $AWS ec2 describe-network-interfaces --filters "Name=attachment.instance-id,Values=$id" \
        --query 'NetworkInterfaces[].[length(PrivateIpAddresses), length(Ipv4Prefixes || `[]`), SubnetId]' --output text |
        awk -v n="$name" '{e++; ips += $1 - 1; pf += $2; sn[$3] = 1}
          END {s = ""; for (k in sn) s = s " " k; printf "%s: %d ENIs, %d secondary IPs, %d /28 prefixes, subnets:%s\n", n, e, ips, pf, s}'
    done
}

current_mode() {  # pod-ip-mode label(s) on the nodes, sorted and joined
  $EKS get nodes -o jsonpath='{range .items[*]}{.metadata.labels.cloudbridge\.io/pod-ip-mode}{"\n"}{end}' | sort -u | paste -sd, -
}

wait_mode() {  # $1 expected pod-ip-mode: wait until exactly NODES_EXPECTED Ready nodes carry it
  local want=$1 end=$(( $(date +%s) + 2700 )) n other
  echo "waiting for the node group to roll to pod-ip-mode=$want (managed rolling update, 10-25 min)..."
  while [ "$(date +%s)" -lt "$end" ]; do
    n=$($EKS get nodes -l "cloudbridge.io/pod-ip-mode=$want" \
      -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c True || true)
    other=$($EKS get nodes -l "cloudbridge.io/pod-ip-mode!=$want" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "  $(date +%H:%M:%S)  ready with $want: $n   other nodes: $other"
    if [ "$n" -ge "$NODES_EXPECTED" ] && [ "$other" = 0 ]; then nodes_table; return 0; fi
    sleep 30
  done
  echo "nodes did not reach pod-ip-mode=$want in 45 min; check the node group update in the EKS console" >&2
  return 1
}

# ---------- capacity ----------

pause_manifest() {
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pause
  namespace: $NS
spec:
  replicas: 0
  selector:
    matchLabels: { app: pause }
  template:
    metadata:
      labels: { app: pause }
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          # Tiny requests: CPU and memory must never be what stops scheduling
          resources:
            requests: { cpu: 1m, memory: 4Mi }
            limits: { memory: 16Mi }
EOF
}

snapshot() {  # one line: desired running unscheduled no_ip per_node
  $EKS get pods -A -o json | jq -r --arg ns "$NS" '
    [.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed")] as $all
    | [$all[] | select(.metadata.namespace == $ns)] as $p
    | ($p | map(select(.status.phase == "Running")) | length) as $run
    | ($p | map(select(.status.phase == "Pending" and (.spec.nodeName // "") == "")) | length) as $unsched
    | ($p | map(select(.status.phase == "Pending" and (.spec.nodeName // "") != "")) | length) as $noip
    | ($all | map(select(.spec.nodeName != null)) | group_by(.spec.nodeName)
        | map("\(.[0].spec.nodeName | split(".")[0])=\(length)") | join(";")) as $pernode
    | "\($run) \($unsched) \($noip) \($pernode)"'
}

first_stuck() {  # first unscheduled pod (FailedScheduling) or first scheduled-but-no-IP pod
  local p
  p=$($EKS -n $NS get pods -o json | jq -r '[.items[] | select(.status.phase == "Pending" and (.spec.nodeName // "") == "")][0].metadata.name // empty')
  if [ -n "$p" ]; then
    echo -n "Pending (unschedulable) $p: "
    $EKS -n $NS get events --field-selector "involvedObject.name=$p" -o json |
      jq -r '[.items[] | select(.reason == "FailedScheduling")] | sort_by(.lastTimestamp // .eventTime) | last | if . == null then "no event yet" else "\(.reason): \(.message)" end' | tr '\n' ' '
    echo
    return
  fi
  p=$($EKS -n $NS get pods -o json | jq -r '[.items[] | select(.status.phase == "Pending" and (.spec.nodeName // "") != "")][0].metadata.name // empty')
  if [ -n "$p" ]; then
    echo -n "ContainerCreating (scheduled, no IP) $p: "
    $EKS -n $NS get events --field-selector "involvedObject.name=$p" -o json |
      jq -r '[.items[] | select(.reason == "FailedCreatePodSandBox")] | sort_by(.lastTimestamp // .eventTime) | last | if . == null then "no event yet" else "\(.reason): \(.message)" end' |
      cut -c1-400 | tr '\n' ' '
    echo
  fi
}

pod_ip_ranges() {  # where the running pause pods got their IPs from
  $EKS -n $NS get pods -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' | grep . |
    python3 -c '
import ipaddress, sys
nets = {"node-2a 10.10.0.0/26": "10.10.0.0/26", "node-2b 10.10.0.64/26": "10.10.0.64/26",
        "pod-2a 10.10.64.0/19": "10.10.64.0/19", "pod-2b 10.10.96.0/19": "10.10.96.0/19"}
c = {k: 0 for k in nets}; other = 0
for l in sys.stdin:
    ip = ipaddress.ip_address(l.strip())
    for k, n in nets.items():
        if ip in ipaddress.ip_network(n): c[k] += 1; break
    else: other += 1
for k, v in c.items(): print(f"  {k:24s} {v} pods")
if other: print(f"  other                    {other} pods")'
}

cmd_capacity() {
  local label=${1:-$(current_mode)} csv txt prev_run=-1 flat=0 step snap run unsched noip pernode free start last stuck
  label=${label//,/+}
  csv=$OUT-capacity-$label.csv
  txt=$OUT-capacity-$label.txt
  [ -n "${KEEP:-}" ] || trap '$EKS -n $NS scale deploy/pause --replicas=0 >/dev/null 2>&1 || true' EXIT

  pause_manifest | $EKS apply -f - >/dev/null
  $EKS -n $NS scale deploy/pause --replicas=0 >/dev/null
  sleep 10
  echo "label,step,time,running,unscheduled,scheduled_no_ip,pods_per_node,free_ips_per_subnet,first_stuck" > "$csv"
  {
    echo "== Test 5 capacity, label=$label, $(ts)"
    echo "-- nodes (MAX_PODS = kubelet max-pods, set when the node launched)"
    nodes_table
    echo "-- ENIs per node"
    enis_per_node
    echo "-- subnets (free = AvailableIpAddressCount)"
    subnets_table
    echo
    for step in $STEPS; do
      $EKS -n $NS scale deploy/pause --replicas="$step" >/dev/null
      # settle: poll every 10 s until two polls agree (min 20 s, max SETTLE)
      start=$(date +%s); last=""
      sleep 10
      while :; do
        snap=$(snapshot)
        [ "$snap" = "$last" ] && [ $(( $(date +%s) - start )) -ge 20 ] && break
        [ $(( $(date +%s) - start )) -ge "$SETTLE" ] && break
        last=$snap; sleep 10
      done
      read -r run unsched noip pernode <<<"$snap"
      free=$(subnets_table | awk '{printf "%s%s=%s", (NR > 1 ? ";" : ""), $1, $3}' | sed 's/cloudbridge-app-//g')
      stuck=$(first_stuck | tr ',' ';')
      printf "step %4d  running %4d  unschedulable %3d  no-IP %3d | per node: %s | free IPs: %s\n" \
        "$step" "$run" "$unsched" "$noip" "$pernode" "$free"
      [ -n "$stuck" ] && echo "           first stuck: $stuck"
      echo "$label,$step,$(ts),$run,$unsched,$noip,$pernode,$free,\"${stuck//\"/\'}\"" >> "$csv"
      # Stop after 2 steps in a row that added no running pods: the limit is reached
      if [ "$run" -le "$prev_run" ]; then flat=$((flat + 1)); else flat=0; fi
      prev_run=$run
      [ $flat -ge 2 ] && { echo "running pods stopped growing at $run: limit reached"; break; }
    done
    echo
    echo "-- where the running pause pods got their IPs"
    pod_ip_ranges
    echo "-- ENIs per node at the end"
    enis_per_node
    echo "-- subnets at the end"
    subnets_table
    echo
    echo "Reading it:"
    echo "  'Too many pods' (FailedScheduling)            -> per-node max-pods limit (ENIs x IPs per ENI)"
    echo "  'failed to assign an IP address' (sandbox)    -> the CNI found no free IP or /28 prefix in the subnet"
  } 2>&1 | tee "$txt"
  echo "saved: $txt $csv"
}

cmd_prefix() {
  echo "pod-ip-mode now: $(current_mode)"
  pause "cd terraform/aws/eks && terraform plan -var enable_prefix_delegation=true -out=prefix.tfplan && caffeinate -i terraform apply prefix.tfplan
# Keep passing -var enable_prefix_delegation=true on every later aws/eks apply until 'restore'."
  wait_mode prefix
  cmd_capacity prefix
}

cmd_custom() {
  echo "pod-ip-mode now: $(current_mode)"
  pause "cd terraform/aws/spoke-app && terraform plan -var enable_secondary_cidr=true -out=secondary.tfplan && terraform apply secondary.tfplan
cd ../eks && terraform plan -var enable_prefix_delegation=true -out=outputs.tfplan && terraform apply outputs.tfplan
# The second apply changes nothing in AWS; it refreshes the eniconfig_subnets output.
# Keep passing these -var flags on every later apply until 'restore'."
  echo "-- subnets"
  subnets_table
  echo "-- applying the ENIConfigs (k8s/eniconfig/render.sh)"
  ../k8s/eniconfig/render.sh | tee "$OUT-eniconfig.yaml" | $EKS apply -f -
  $EKS get eniconfigs.crd.k8s.amazonaws.com -o custom-columns='NAME:.metadata.name,SUBNET:.spec.subnet,SG:.spec.securityGroups[0]'
  pause "cd terraform/aws/eks && terraform plan -var enable_prefix_delegation=true -var enable_custom_networking=true -out=custom.tfplan && caffeinate -i terraform apply custom.tfplan
# This rolls the node group (new launch template version); the script waits for it."
  wait_mode prefix-custom-net
  echo "-- app pod IPs after the roll (expect 10.10.64.0/18)"
  $EKS -n cloudbridge get pods -o custom-columns='POD:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName' | tee "$OUT-custom-app-pods.txt"
  cmd_capacity prefix-custom-net
}

cmd_restore() {
  echo "pod-ip-mode now: $(current_mode)"
  pause "cd terraform/aws/eks && terraform plan -out=restore.tfplan && caffeinate -i terraform apply restore.tfplan   # both toggles back to false; nodes roll
# Wait until 'kubectl --context cloudbridge-eks get nodes -L cloudbridge.io/pod-ip-mode' shows secondary-ip on all nodes,
# then remove the pod subnets (they must have no ENIs left):
cd ../spoke-app && terraform plan -out=restore.tfplan && terraform apply restore.tfplan"
  $EKS delete eniconfigs.crd.k8s.amazonaws.com --all --ignore-not-found
  $EKS delete namespace $NS --ignore-not-found --wait=false
  nodes_table
}

# ---------- netshoot pods ----------

nsh_manifest() {  # $1 name, $2 hostNetwork true|false, $3 command
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: default
  labels: { app: cb-nsh }
spec:
  hostNetwork: $2
  terminationGracePeriodSeconds: 0
  containers:
    - name: nsh
      image: $NSH_IMAGE
      command: ["sh", "-c", "$3"]
      securityContext:
        capabilities: { add: [NET_ADMIN, NET_RAW] }
EOF
}

nsh_up() {
  nsh_manifest cb-nsh false "iperf3 -s -p 5201" | $EKS apply -f - >/dev/null
  nsh_manifest cb-nsh false "iperf3 -s -p 5201" | $AKS apply -f - >/dev/null
  # Host-network pod on the (single) AKS node: tcpdump there sees what arrives at the node
  nsh_manifest cb-nsh-host true "sleep infinity" | $AKS apply -f - >/dev/null
  $EKS wait --for=condition=Ready pod/cb-nsh --timeout=240s >/dev/null
  $AKS wait --for=condition=Ready pod/cb-nsh pod/cb-nsh-host --timeout=240s >/dev/null
}

pod_ip() { $1 get pod "$2" -o jsonpath='{.status.podIP}'; }
node_ip_of() { $1 get node "$($1 get pod "$2" -o jsonpath='{.spec.nodeName}')" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }

try() {  # run, print the exit code, never abort
  local rc=0
  "$@" 2>&1 || rc=$?
  echo "  -> exit $rc"
}

sources() {  # unique source IPs in a tcpdump -nn text file
  grep -oE ' IP [0-9.]+(\.[0-9]+)? > ' "$1" | awk '{split($2, a, "."); print a[1] "." a[2] "." a[3] "." a[4]}' | sort | uniq -c || true
}

tgw_lpm() {  # $1 route table role, $2 IP: longest-prefix match in that TGW route table
  local rt
  rt=$($AWS ec2 describe-transit-gateway-route-tables --filters "Name=tag:Name,Values=cloudbridge-tgw-rt-$1" \
    --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' --output text)
  $AWS ec2 search-transit-gateway-routes --transit-gateway-route-table-id "$rt" \
    --filters "Name=route-search.longest-prefix-match,Values=$2/32" "Name=state,Values=active,blackhole" \
    --query 'Routes[0].[DestinationCidrBlock,Type,State,TransitGatewayAttachments[0].ResourceType]' --output text 2>/dev/null || echo "lookup failed"
}

cmd_xcloud() {
  local out=$OUT-xcloud.txt tmp eks_pod aks_pod aks_node aks_host_ip eks_node eks_backend
  tmp=$(mktemp -d)
  nsh_up
  eks_pod=$(pod_ip "$EKS" cb-nsh); aks_pod=$(pod_ip "$AKS" cb-nsh)
  eks_node=$(node_ip_of "$EKS" cb-nsh); aks_node=$(node_ip_of "$AKS" cb-nsh)
  aks_host_ip=$(pod_ip "$AKS" cb-nsh-host)
  eks_backend=$($EKS -n cloudbridge get pods -l app=backend -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
  {
    echo "== Test 5 cross-cloud pod networking, $(ts)"
    echo "EKS netshoot pod $eks_pod on node $eks_node    (VPC CNI: the pod IP is a VPC IP)"
    echo "AKS netshoot pod $aks_pod on node $aks_node    (Overlay: 10.244.0.0/16, never routed outside the cluster)"
    echo "EKS backend pod  ${eks_backend:-<none: deploy the app first>}"
    echo

    echo "== 1. AKS pod -> EKS pod IP, direct (expect: works)"
    # Inbound only: echo requests and SYNs addressed to this pod, so the source is the caller as seen here
    $EKS exec cb-nsh -- timeout 25 tcpdump -nn -l -i eth0 -c 12 \
      "dst host $eks_pod and (icmp[icmptype] = icmp-echo or (tcp dst port 5201 and tcp[tcpflags] & tcp-syn != 0))" > "$tmp/eks.cap" 2>&1 &
    local cap=$!
    sleep 5
    echo "-- ping"; try $AKS exec cb-nsh -- ping -c 3 -W 2 "$eks_pod"
    echo "-- TCP 5201 (iperf3 listener in the EKS pod)"; try $AKS exec cb-nsh -- nc -zv -w 3 "$eks_pod" 5201
    if [ -n "$eks_backend" ]; then
      echo "-- HTTP to the EKS backend pod IP"; try $AKS exec cb-nsh -- curl -s -m 5 "http://$eks_backend:8080/"; echo
    fi
    wait $cap || true
    echo "-- tcpdump in the EKS pod (the far side):"
    sed 's/^/   /' "$tmp/eks.cap" | head -14
    echo "-- source IPs that arrived at the EKS pod:"
    sources "$tmp/eks.cap"
    echo "   AKS pod IP is $aks_pod, AKS node IP is $aks_node: the source above is the NODE."
    echo "   Cilium SNATs pod traffic leaving the overlay to the node IP, so EKS never sees 10.244.x."
    echo

    echo "== 2. EKS pod -> AKS pod IP (expect: fails, overlay addresses aren't routed)"
    $AKS exec cb-nsh-host -- timeout 20 tcpdump -nn -l -i any -c 20 "host $eks_pod" > "$tmp/aks2.cap" 2>&1 &
    cap=$!
    sleep 5
    echo "-- ping"; try $EKS exec cb-nsh -- ping -c 3 -W 2 "$aks_pod"
    echo "-- TCP 5201"; try $EKS exec cb-nsh -- nc -zv -w 3 "$aks_pod" 5201
    wait $cap || true
    echo "-- tcpdump on the AKS node for host $eks_pod: $(grep -c ' IP ' "$tmp/aks2.cap" || true) packets (expect 0: nothing arrives)"
    echo "-- why: TGW longest-prefix match for $aks_pod"
    echo "   spokes table:     $(tgw_lpm spokes "$aks_pod")      (0.0.0.0/0 -> inspection, i.e. towards the internet NAT)"
    echo "   inspection table: $(tgw_lpm inspection "$aks_pod")"
    echo "   10.244.0.0/16 is not in any TGW table and not advertised over BGP; only 10.20.0.0/20 and"
    echo "   10.20.240.0/22 are. Compare $ILB_IP: spokes table $(tgw_lpm spokes $ILB_IP), inspection $(tgw_lpm inspection $ILB_IP)"
    echo

    echo "== 3. EKS pod -> AKS frontend through the internal LB $ILB_IP (expect: works)"
    # SYNs from anywhere in AWS (10.10.0.0/16), on every interface of the node: eth0 before the LB
    # translation and the pod's lxc interface after it. Whatever source arrives is what is printed.
    $AKS exec cb-nsh-host -- timeout 20 tcpdump -nn -l -i any -c 12 \
      "src net 10.10.0.0/16 and tcp[tcpflags] & tcp-syn != 0" > "$tmp/aks3.cap" 2>&1 &
    cap=$!
    sleep 5
    try $EKS exec cb-nsh -- curl -s -m 5 "http://$ILB_IP/"; echo
    wait $cap || true
    echo "-- tcpdump on the AKS node (the far side):"
    sed 's/^/   /' "$tmp/aks3.cap" | head -14
    echo "-- source IPs that arrived at the AKS node:"
    sources "$tmp/aks3.cap"
    echo "   EKS pod IP is $eks_pod, EKS node IP is $eks_node: the source above is the POD."
    echo "   The VPC CNI leaves 10.20.0.0/16 out of its SNAT (AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS),"
    echo "   and no firewall on the path NATs private-to-private traffic."
    echo
    echo "Summary: EKS pod IPs are routable VPC addresses, so Azure can call them directly and sees"
    echo "them unchanged. AKS overlay pod IPs exist only inside the cluster: AWS reaches AKS through"
    echo "the internal LB (a VNet IP), and AKS pods appear in AWS as their node IP."
  } 2>&1 | tee "$out"
  rm -rf "$tmp"
  echo "saved: $out   (netshoot pods stay up for 'private'; remove with: $0 cleanup)"
}

cmd_private() {
  local out=$OUT-private.txt sa sas dns bucket exp
  nsh_up
  sa=$(terraform -chdir=$TF/azure/hub output -raw storage_account_name)
  dns=$(terraform -chdir=$TF/aws/spoke-app output -raw s3_interface_dns); dns=${dns#\*.}
  bucket=$(terraform -chdir=$TF/aws/spoke-app output -raw probe_bucket)
  exp=$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(minutes=15)).strftime("%Y-%m-%dT%H:%MZ"))')
  # Read-only SAS for the one probe blob, valid 15 min. It is passed to curl and never printed.
  sas=$(az storage blob generate-sas --account-name "$sa" -c probe -n hello.txt --permissions r \
    --expiry "$exp" --https-only --auth-mode key -o tsv 2>/dev/null || true)
  {
    echo "== Test 5 private DNS and private access, $(ts)"
    echo
    echo "== DNS, AKS pod -> AWS private zone (CoreDNS -> node resolver = Azure fw dnsmasq -> AWS fw -> VPC resolver)"
    try $AKS exec cb-nsh -- dig +short fw-a.cloudbridge.internal
    echo "   expect 10.10.240.40"
    echo "== DNS, EKS pod -> Azure private zone (CoreDNS stanza k8s/coredns-eks -> AWS fw -> Azure fw -> 168.63.129.16)"
    try $EKS exec cb-nsh -- dig +short fw.az.cloudbridge.internal
    echo "   expect 10.20.241.4"
    echo
    echo "== EKS pod reads the Azure blob through the Private Endpoint"
    try $EKS exec cb-nsh -- dig +short "$sa.blob.core.windows.net"
    echo "   expect a CNAME to $sa.privatelink.blob.core.windows.net and an A record in 10.20.5.0/27"
    if [ -n "$sas" ]; then
      try $EKS exec cb-nsh -- curl -s -m 10 -w '   remote_ip=%{remote_ip} http=%{http_code}\n' \
        "https://$sa.blob.core.windows.net/probe/hello.txt?$sas"
      echo "   expect the blob text, remote_ip 10.20.5.x (path: EKS -> TGW -> AWS fw -> VPN -> Azure fw (SNAT) -> PE)"
    else
      echo "   could not create a SAS (az storage blob generate-sas --auth-mode key needs listKeys on $sa)"
    fi
    echo
    echo "== AKS pod reads S3 through the interface endpoint (over the VPN)"
    try $AKS exec cb-nsh -- dig +short "$bucket.$dns"
    echo "   expect private IPs in 10.10.0.0/26 (the endpoint ENI in 2a)"
    try $AKS exec cb-nsh -- curl -s -m 10 -w '   remote_ip=%{remote_ip} http=%{http_code}\n' "https://$bucket.bucket.$dns/hello.txt"   # S3 interface endpoints need the literal "bucket." label (TLS cert: *.bucket.vpce-...)
    echo "   expect 'hello from AWS S3 over PrivateLink', http 200"
    echo "-- the same object through the public S3 endpoint (expect 403: the bucket policy requires the endpoint)"
    try $AKS exec cb-nsh -- curl -s -o /dev/null -m 10 -w '   remote_ip=%{remote_ip} http=%{http_code}\n' \
      "https://$bucket.s3.us-east-2.amazonaws.com/hello.txt"
  } 2>&1 | tee "$out"
  echo "saved: $out"
}

cmd_cleanup() {
  $EKS delete pod cb-nsh --ignore-not-found --wait=false
  $AKS delete pod cb-nsh cb-nsh-host --ignore-not-found --wait=false
  $EKS delete namespace $NS --ignore-not-found --wait=false
}

case "${1:-}" in
  capacity) cmd_capacity "${2:-}" ;;
  prefix)   cmd_prefix ;;
  custom)   cmd_custom ;;
  restore)  cmd_restore ;;
  xcloud)   cmd_xcloud ;;
  private)  cmd_private ;;
  cleanup)  cmd_cleanup ;;
  *) echo "usage: $0 capacity [label]|prefix|custom|restore|xcloud|private|cleanup" >&2; exit 1 ;;
esac
