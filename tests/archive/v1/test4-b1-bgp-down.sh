#!/usr/bin/env bash
# Test 4 / B1 + Test 5 / C1: which tunnel carries traffic, and what happens when BGP on that
# tunnel fails while IPsec stays up.
#
#   C1  Path selection: push a little iperf3 traffic each way and read Azure's per-connection
#       byte counters to see which tunnel AWS uses to send, and which one Azure uses.
#   B1  Break BGP on the tunnel AWS is sending on (wrong peer ASN on its Azure local network
#       gateway), keep a 5/s ping running across the VPN, time the reroute, then restore.
#
# Usage: ./test4-b1-bgp-down.sh
set -euo pipefail
cd "$(dirname "$0")"

RG=cloudbridge-rg
GW=cloudbridge-vpngw
OUT=../docs/runs/test4-b1
BROKEN=180      # seconds to leave BGP broken
RECOVERY=240    # seconds to watch after restoring
AWS_ASN=64512
BAD_ASN=65000   # any ASN AWS isn't using: Azure will reject AWS's BGP OPEN

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
bytes() {  # ingress/egress bytes on one Azure connection (ingress = received from AWS)
  az network vpn-connection show -g $RG -n "cloudbridge-conn-aws-$1" \
    --query "[ingressBytesTransferred, egressBytesTransferred]" -o tsv 2>/dev/null | tr '\t' ' '
}
peers() {  # "169.254.21.1=Connected 169.254.22.1=Connected"
  az network vnet-gateway list-bgp-peer-status -g $RG -n $GW \
    --query "value[].[neighbor,state]" -o tsv 2>/dev/null | awk '{printf "%s=%s ", $1, $2}'
}

mkdir -p ../docs/runs
read -r EKS_IP AZ_IP <<<"$(./netshoot.sh)"
echo "EKS pod $EKS_IP  ->  AKS pod $AZ_IP"
NSH="kubectl --context cloudbridge-eks exec nsh --"

# ---------------- C1: path selection ----------------
read -r i1a e1a <<<"$(bytes t1)"; read -r i2a e2a <<<"$(bytes t2)"
$NSH iperf3 -c "$AZ_IP" -t 15 -b 20M >/dev/null        # AWS -> Azure
$NSH iperf3 -c "$AZ_IP" -t 15 -b 20M -R >/dev/null     # Azure -> AWS (reverse)
sleep 20  # Azure's counters lag a little
read -r i1b e1b <<<"$(bytes t1)"; read -r i2b e2b <<<"$(bytes t2)"

{
  echo "direction,t1_MB,t2_MB"
  echo "aws_to_azure,$(( (i1b - i1a) / 1000000 )),$(( (i2b - i2a) / 1000000 ))"
  echo "azure_to_aws,$(( (e1b - e1a) / 1000000 )),$(( (e2b - e2a) / 1000000 ))"
} | tee "$OUT-paths.csv"

ACTIVE=t1; [ $(( i2b - i2a )) -gt $(( i1b - i1a )) ] && ACTIVE=t2
echo "AWS is sending on tunnel $ACTIVE -> breaking BGP there"

# ---------------- B1: BGP down on the active tunnel ----------------
# 5 pings/s with timestamps (-D); -O prints a line for every missed reply
$NSH sh -c "ping -D -O -i 0.2 $AZ_IP" > "$OUT-ping.txt" 2>&1 &
PING=$!
trap 'kill $PING 2>/dev/null; az network local-gateway update -g $RG -n cloudbridge-lng-aws-$ACTIVE --asn $AWS_ASN -o none 2>/dev/null' EXIT
sleep 15

echo "epoch_ms,phase,peers,t1_status,t2_status" > "$OUT-state.csv"
watch_state() {  # $1 = phase, $2 = seconds
  local end=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    s1=$(az network vpn-connection show -g $RG -n cloudbridge-conn-aws-t1 --query connectionStatus -o tsv 2>/dev/null)
    s2=$(az network vpn-connection show -g $RG -n cloudbridge-conn-aws-t2 --query connectionStatus -o tsv 2>/dev/null)
    echo "$(now_ms),$1,$(peers),$s1,$s2" >> "$OUT-state.csv"
    sleep 5
  done
}

BREAK=$(now_ms)
az network local-gateway update -g $RG -n "cloudbridge-lng-aws-$ACTIVE" --asn $BAD_ASN -o none
echo "broke BGP on $ACTIVE (peer ASN $AWS_ASN -> $BAD_ASN), watching ${BROKEN}s..."
watch_state broken "$BROKEN"

RESTORE=$(now_ms)
az network local-gateway update -g $RG -n "cloudbridge-lng-aws-$ACTIVE" --asn $AWS_ASN -o none
echo "restored ASN, watching ${RECOVERY}s..."
watch_state restored "$RECOVERY"

kill $PING 2>/dev/null || true
trap - EXIT
echo "break=$BREAK restore=$RESTORE active=$ACTIVE" > "$OUT.meta"
python3 analyze4.py "$OUT-ping.txt" "$OUT-state.csv" "$BREAK" "$RESTORE"
