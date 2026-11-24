#!/usr/bin/env bash
# Test 3: terminate one EKS worker (EC2 instance) and measure how long Kubernetes and the
# ALB take to route around it. Run once with overlays/aws (defaults) and once with
# overlays/aws-tuned applied, 3 times each.
#
# The probe hits the ALB directly: Route 53 should NOT fail over here (the other node keeps
# serving), so this measures the regional layer only.
# Usage: ./test3-node-failure.sh <label>      e.g. default-1, tuned-2
set -euo pipefail
cd "$(dirname "$0")"

LABEL="${1:?usage: $0 <label>}"
OUT="../docs/runs/test3-${LABEL}"
K="kubectl --context cloudbridge-eks"
MAX_WAIT=900       # stop watching after 15 min even if not recovered
POST_RECOVERY=150  # keep probing this long after pods recover, to catch ALB-side errors

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
ready() { $K -n cloudbridge get pods -l app="$1" -o json |
  python3 -c 'import json,sys; p=json.load(sys.stdin)["items"]; print(sum(all(c.get("ready") for c in x["status"].get("containerStatuses",[])) and x["metadata"].get("deletionTimestamp") is None for x in p))'; }

ALB=$($K -n cloudbridge get ingress frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Pre-flight: all 6 pods Ready on 2 Ready nodes
until [ "$(ready frontend)" = 3 ] && [ "$(ready backend)" = 3 ] &&
      [ "$($K get nodes --no-headers | grep -c ' Ready')" = 2 ]; do
  echo "waiting for 3+3 Ready pods on 2 Ready nodes..."; sleep 10
done

# Rebalance: after a previous run all pods sit on the surviving node, and Kubernetes never moves
# running pods back. A rolling restart lets topology spread place them across both nodes again,
# so every run starts from the same layout.
$K -n cloudbridge rollout restart deploy/frontend deploy/backend >/dev/null
$K -n cloudbridge rollout status deploy/frontend --timeout=300s >/dev/null
$K -n cloudbridge rollout status deploy/backend --timeout=300s >/dev/null
sleep 20  # let the ALB register the new pod IPs and mark them healthy

# Victim: the node running the most frontend pods (worst case for the ALB)
NODE=$($K -n cloudbridge get pods -l app=frontend -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
INSTANCE=$($K get node "$NODE" -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')
echo "victim: $NODE ($INSTANCE)"

mkdir -p ../docs/runs
./probe.sh "http://$ALB/" > "$OUT.csv" &
PROBE=$!
trap 'kill $PROBE 2>/dev/null' EXIT
sleep 20

BREAK=$(now_ms)
aws ec2 terminate-instances --instance-ids "$INSTANCE" --query 'TerminatingInstances[0].CurrentState.Name' --output text

# Timeline: when the node went NotReady, when its pods were evicted, when 3+3 were Ready again
echo "epoch_ms,node_ready,frontend_ready,backend_ready" > "$OUT.pods.csv"
END=$(( $(date +%s) + MAX_WAIT ))
while [ "$(date +%s)" -lt "$END" ]; do
  nr=$($K get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo gone)
  f=$(ready frontend); b=$(ready backend)
  echo "$(now_ms),${nr:-gone},$f,$b" >> "$OUT.pods.csv"
  # Pods recovered: victim is gone/NotReady and all 6 pods are Ready again elsewhere.
  # Keep probing afterwards: the ALB can keep sending to dead pod IPs long after Kubernetes
  # has recovered, and that is what users see (found in the first default run).
  if [ "$nr" != "True" ] && [ "$f" = 3 ] && [ "$b" = 3 ] &&
     ! $K -n cloudbridge get pods -o wide --no-headers | grep -q "$NODE"; then
    sleep "$POST_RECOVERY"; break
  fi
  sleep 2
done

kill $PROBE
echo "break=$BREAK node=$NODE instance=$INSTANCE" > "$OUT.meta"
python3 analyze3.py "$OUT.csv" "$OUT.pods.csv" "$BREAK"
