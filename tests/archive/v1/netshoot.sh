#!/usr/bin/env bash
# Start (or reuse) a "netshoot" debug pod in each cluster: ping, iperf3, tcpdump, dig, curl, mtr.
# The AKS pod also runs an iperf3 server. Prints the two pod IPs as: EKS_IP AZ_IP
#   ./netshoot.sh          start / reuse
#   ./netshoot.sh delete   remove both
set -euo pipefail

IMAGE="nicolaka/netshoot:v0.13"

if [ "${1:-}" = "delete" ]; then
  kubectl --context cloudbridge-eks delete pod nsh --ignore-not-found --wait=false >/dev/null
  kubectl --context cloudbridge-aks delete pod nsh --ignore-not-found --wait=false >/dev/null
  exit 0
fi

for ctx in cloudbridge-eks cloudbridge-aks; do
  if ! kubectl --context "$ctx" get pod nsh >/dev/null 2>&1; then
    cmd="sleep infinity"
    [ "$ctx" = cloudbridge-aks ] && cmd="iperf3 -s"
    kubectl --context "$ctx" run nsh --image="$IMAGE" --restart=Never --command -- sh -c "$cmd" >/dev/null
  fi
  kubectl --context "$ctx" wait --for=condition=Ready pod/nsh --timeout=180s >/dev/null
done

echo "$(kubectl --context cloudbridge-eks get pod nsh -o jsonpath='{.status.podIP}') \
$(kubectl --context cloudbridge-aks get pod nsh -o jsonpath='{.status.podIP}')"
