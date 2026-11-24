#!/usr/bin/env bash
# Test 4 / B2: MTU and MSS across the IPsec tunnels.
#   1. Interface MTU on each side (EKS pods use jumbo 9001, AKS pods 1500)
#   2. Path MTU each way: largest ping that fits with Don't Fragment set
#   3. tracepath: where the MTU drops
#   4. TCP MSS: what the sender offers vs what arrives across the VPN (gateway clamping)
# Usage: ./test4-b2-mtu.sh
set -euo pipefail
cd "$(dirname "$0")"

read -r EKS_IP AZ_IP <<<"$(./netshoot.sh)"
EKS="kubectl --context cloudbridge-eks exec nsh --"
AKS="kubectl --context cloudbridge-aks exec nsh --"
OUT=../docs/runs/test4-b2.txt
mkdir -p ../docs/runs

# Largest ICMP payload that gets through with DF set (binary search). +28 = IP + ICMP headers
pmtu() {  # $1 = exec prefix, $2 = target
  local lo=1000 hi=8972 mid
  while [ $(( hi - lo )) -gt 1 ]; do
    mid=$(( (lo + hi) / 2 ))
    if $1 ping -M do -c 1 -W 1 -s "$mid" "$2" >/dev/null 2>&1; then lo=$mid; else hi=$mid; fi
  done
  echo "$lo"
}

{
  echo "== Interface MTU"
  echo "EKS pod eth0: $($EKS cat /sys/class/net/eth0/mtu)"
  echo "AKS pod eth0: $($AKS cat /sys/class/net/eth0/mtu)"

  echo; echo "== Path MTU with DF set (largest payload + 28 bytes of headers)"
  p=$(pmtu "$EKS" "$AZ_IP"); echo "AWS -> Azure: payload $p  =>  path MTU $(( p + 28 ))"
  p=$(pmtu "$AKS" "$EKS_IP"); echo "Azure -> AWS: payload $p  =>  path MTU $(( p + 28 ))"
  echo "One byte too big, AWS -> Azure:"
  $EKS ping -M do -c 1 -W 1 -s $(( $(pmtu "$EKS" "$AZ_IP") + 1 )) "$AZ_IP" 2>&1 | tail -2 || true

  echo; echo "== tracepath AWS -> Azure"
  $EKS tracepath -n -m 10 "$AZ_IP" 2>&1 | tail -6 || true

  echo; echo "== TCP MSS: SYN as sent by the EKS pod vs as received by the AKS pod"
  $AKS sh -c "timeout 12 tcpdump -nn -v -c 1 -i eth0 'tcp[tcpflags] & tcp-syn != 0 and dst port 5201' 2>/dev/null" > /tmp/b2-rx.txt &
  $EKS sh -c "timeout 12 tcpdump -nn -v -c 1 -i eth0 'tcp[tcpflags] & tcp-syn != 0 and dst port 5201' 2>/dev/null" > /tmp/b2-tx.txt &
  sleep 3
  $EKS iperf3 -c "$AZ_IP" -t 2 -b 5M >/dev/null 2>&1 || true
  wait
  echo "sent     : $(grep -o 'mss [0-9]*' /tmp/b2-tx.txt | head -1)"
  echo "received : $(grep -o 'mss [0-9]*' /tmp/b2-rx.txt | head -1)"
} | tee "$OUT"
