#!/usr/bin/env bash
# Test 5 / C2: full AWS region loss — the app AND the private network path.
#   app:     scale every EKS pod to 0 (like Test 2)
#   network: wrong pre-shared key on both Azure connections -> IKE fails -> both tunnels down
# Shows: (1) Route 53 still fails over (it never depends on the VPN), (2) BGP withdraws
# 10.10.0.0/16 from Azure and 10.20.0.0/16 from AWS, (3) the VPN alarms fire.
#
# Restore is in two parts, on purpose:
#   ./test5-c2-region-vpn.sh break      break both, watch failover + route withdrawal (~12 min)
#   (user)  cd terraform/connectivity/vpn && terraform plan && terraform apply   <- runbook "drift" fix
#   ./test5-c2-region-vpn.sh restore    scale the app back, time tunnel + BGP recovery
set -euo pipefail
cd "$(dirname "$0")"

RG=cloudbridge-rg
OUT=../docs/runs/test5-c2
K="kubectl --context cloudbridge-eks -n cloudbridge"
RTB=$(terraform -chdir=../terraform/aws/network output -json private_route_table_ids | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')
VPN=$(terraform -chdir=../terraform/connectivity/vpn output -raw vpn_connection_id)
mkdir -p ../docs/runs

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
snapshot() {  # one CSV line: tunnels, Azure BGP, routes each side, alarm states
  local aws_t az_conn az_bgp az_routes aws_route alarms
  aws_t=$(aws ec2 describe-vpn-connections --vpn-connection-ids "$VPN" --query "VpnConnections[0].VgwTelemetry[].Status" --output text | tr '\t' '/')
  az_conn=$(az network vpn-connection list -g $RG --query "[].connectionStatus" -o tsv 2>/dev/null | tr '\n' '/')
  az_bgp=$(az network vnet-gateway list-bgp-peer-status -g $RG -n cloudbridge-vpngw --query "value[].state" -o tsv 2>/dev/null | tr '\n' '/')
  az_routes=$(az network vnet-gateway list-learned-routes -g $RG -n cloudbridge-vpngw --query "length(value[?origin=='EBgp'])" -o tsv 2>/dev/null)
  aws_route=$(aws ec2 describe-route-tables --route-table-ids "$RTB" --query "length(RouteTables[0].Routes[?DestinationCidrBlock=='10.20.0.0/16'])" --output text)
  alarms=$(aws cloudwatch describe-alarms --alarm-name-prefix cloudbridge-vpn --query "MetricAlarms[].StateValue" --output text | tr '\t' '/')
  echo "$(now_ms),$1,$aws_t,$az_conn,$az_bgp,$az_routes,$aws_route,$alarms"
}
watch() {  # $1 phase, $2 seconds
  local end=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$end" ]; do snapshot "$1" | tee -a "$OUT-state.csv"; sleep 20; done
}

case "${1:-}" in
  break)
    echo "waiting for steady AWS traffic..."
    ok=0; until [ "$ok" -ge 10 ]; do
      curl -s --max-time 2 http://app.jeevs.click/ | grep -q '"cloud":"aws"' && ok=$((ok + 1)) || ok=0; sleep 1; done
    echo "epoch_ms,phase,aws_tunnels,az_connections,az_bgp,az_learned_routes,aws_route_10.20,alarms" > "$OUT-state.csv"
    ./probe.sh > "$OUT-probe.csv" & echo $! > "$OUT.probe.pid"
    snapshot baseline | tee -a "$OUT-state.csv"; sleep 30

    BREAK=$(now_ms)
    $K scale deploy/frontend deploy/backend --replicas=0 >/dev/null
    for t in t1 t2; do
      az network vpn-connection shared-key update -g $RG --connection-name "cloudbridge-conn-aws-$t" \
        --value "wrongKeyForTestC2" -o none
    done
    echo "break=$BREAK" > "$OUT.meta"
    echo "broke app + both tunnels at $BREAK; watching 12 min (alarms use 5-min periods)..."
    watch broken 720
    echo
    echo "NEXT (you run): cd terraform/connectivity/vpn && terraform plan   # should show the shared_key drift"
    echo "                then terraform apply, then: ./test5-c2-region-vpn.sh restore"
    ;;

  restore)
    RESTORE=$(now_ms)
    echo "restore=$RESTORE" >> "$OUT.meta"
    $K scale deploy/frontend deploy/backend --replicas=3 >/dev/null
    watch restored 600
    kill "$(cat "$OUT.probe.pid")" 2>/dev/null || true; rm -f "$OUT.probe.pid"
    BREAK=$(sed -n 's/^break=//p' "$OUT.meta")
    python3 analyze.py "$OUT-probe.csv" "$BREAK" "$RESTORE"
    ;;

  *) echo "usage: $0 break|restore" >&2; exit 1 ;;
esac
