#!/usr/bin/env bash
# Test 4 / B3: tunnels and BGP are fine, but the route never reaches the subnet.
# Turn off VGW route propagation on the private route table, then diagnose it the way you
# would in production: route table -> VPC Reachability Analyzer -> Azure effective routes.
# Usage: ./test4-b3-route-propagation.sh
set -euo pipefail
cd "$(dirname "$0")"

NET=../terraform/aws/network
RTB=$(terraform -chdir=$NET output -json private_route_table_ids | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])')
VGW=$(terraform -chdir=$NET output -raw vgw_id)
read -r EKS_IP AZ_IP <<<"$(./netshoot.sh)"
EKS="kubectl --context cloudbridge-eks exec nsh --"
OUT=../docs/runs/test4-b3.txt
mkdir -p ../docs/runs
trap 'aws ec2 enable-vgw-route-propagation --route-table-id $RTB --gateway-id $VGW 2>/dev/null' EXIT

routes() { aws ec2 describe-route-tables --route-table-ids "$RTB" \
  --query "RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId||NatGatewayId,Origin]" --output text; }
ping3() { $EKS ping -c 3 -W 1 "$AZ_IP" 2>&1 | grep -E 'packets transmitted' || true; }

# Reachability Analyzer: path from the ENI holding the EKS pod's IP to the VGW, for the Azure IP.
# It reasons over the configuration (no packets sent) and names the component that blocks.
analyze() {
  local eni path ana
  eni=$(aws ec2 describe-network-interfaces --filters "Name=addresses.private-ip-address,Values=$EKS_IP" \
        --query 'NetworkInterfaces[0].NetworkInterfaceId' --output text)
  path=$(aws ec2 create-network-insights-path --source "$eni" --destination "$VGW" \
        --destination-ip "$AZ_IP" --protocol tcp --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text)
  ana=$(aws ec2 start-network-insights-analysis --network-insights-path-id "$path" \
        --query 'NetworkInsightsAnalysis.NetworkInsightsAnalysisId' --output text)
  until [ "$(aws ec2 describe-network-insights-analyses --network-insights-analysis-ids "$ana" \
            --query 'NetworkInsightsAnalyses[0].Status' --output text)" != running ]; do sleep 5; done
  aws ec2 describe-network-insights-analyses --network-insights-analysis-ids "$ana" --query \
    'NetworkInsightsAnalyses[0].{reachable:NetworkPathFound,why:Explanations[0].ExplanationCode,component:Explanations[0].Component.Id}' --output table
  aws ec2 delete-network-insights-analysis --network-insights-analysis-id "$ana" >/dev/null
  aws ec2 delete-network-insights-path --network-insights-path-id "$path" >/dev/null
}

{
  echo "== Baseline"; routes; ping3

  echo; echo "== Break: disable VGW route propagation on $RTB"
  aws ec2 disable-vgw-route-propagation --route-table-id "$RTB" --gateway-id "$VGW"
  sleep 10
  routes; ping3
  echo "-- tunnels (still fine):"
  aws ec2 describe-vpn-connections --query "VpnConnections[].VgwTelemetry[].[OutsideIpAddress,Status,StatusMessage]" --output text
  echo "-- Azure still has a route back to AWS (only one direction is broken):"
  az network vnet-gateway list-learned-routes -g cloudbridge-rg -n cloudbridge-vpngw \
    --query "value[?origin=='EBgp'].[network,nextHop]" -o tsv 2>/dev/null
  echo "-- Reachability Analyzer (broken):"; analyze

  echo; echo "== Fix: re-enable propagation"
  aws ec2 enable-vgw-route-propagation --route-table-id "$RTB" --gateway-id "$VGW"
  sleep 15
  routes; ping3
  echo "-- Reachability Analyzer (fixed):"; analyze
} 2>&1 | tee "$OUT"
