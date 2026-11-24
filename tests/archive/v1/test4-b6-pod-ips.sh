#!/usr/bin/env bash
# Test 4 / B6: pod capacity on EKS is set by ENIs and IPs per instance type, not CPU.
# VPC CNI gives every pod a real VPC IP from the node's ENIs. t3.medium: 3 ENIs x 6 IPv4 each.
#   max pods = ENIs x (IPs per ENI - 1) + 2 = 3 x 5 + 2 = 17   (the "-1" is each ENI's primary IP;
#   "+2" covers host-network pods like aws-node and kube-proxy, which don't use a pod IP)
# Scale the backend to 30 replicas and watch pods go Pending once the nodes are full.
# Usage: ./test4-b6-pod-ips.sh
set -euo pipefail
cd "$(dirname "$0")"

K="kubectl --context cloudbridge-eks"
OUT=../docs/runs/test4-b6.txt
mkdir -p ../docs/runs
trap '$K -n cloudbridge scale deploy/backend --replicas=3 >/dev/null' EXIT

per_node() { $K get pods -A -o wide --no-headers --field-selector=status.phase=Running |
  awk '{print $8}' | sort | uniq -c; }

{
  echo "== Node capacity (allocatable pods) and ENIs"
  $K get nodes -o custom-columns='NODE:.metadata.name,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,MAX_PODS:.status.allocatable.pods,CPU:.status.allocatable.cpu'
  for id in $($K get nodes -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' | awk -F/ '{print $NF}'); do
    aws ec2 describe-network-interfaces --filters "Name=attachment.instance-id,Values=$id" \
      --query "NetworkInterfaces[].[NetworkInterfaceId,length(PrivateIpAddresses)]" --output text |
      awk -v i="$id" '{n++; ips+=$2} END {print i": "n" ENIs, "ips" IPs in use"}'
  done
  echo "-- running pods per node:"; per_node

  echo; echo "== Scale backend 3 -> 30"
  $K -n cloudbridge scale deploy/backend --replicas=30 >/dev/null
  sleep 60
  echo "backend pods by phase:"
  $K -n cloudbridge get pods -l app=backend --no-headers | awk '{print $3}' | sort | uniq -c
  echo "-- running pods per node:"; per_node
  echo "-- why a Pending pod is stuck:"
  P=$($K -n cloudbridge get pods -l app=backend --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "$P" ] && $K -n cloudbridge get events --field-selector "involvedObject.name=$P" \
    -o custom-columns='REASON:.reason,MESSAGE:.message' --no-headers | tail -2
  echo "-- CPU requested vs allocatable (to show CPU is NOT the limit):"
  $K describe nodes | grep -A6 'Allocated resources' | grep -E 'cpu|memory' | head -4

  echo; echo "== Restore: backend -> 3"
} 2>&1 | tee "$OUT"
