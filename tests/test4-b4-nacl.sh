#!/usr/bin/env bash
# Test 4 / B4: a stateless NACL breaks return traffic — "it works one way only".
# Add an inbound NACL rule that denies TCP to the Linux ephemeral port range (32768-65535)
# from Azure. Security groups are stateful (replies are allowed automatically); NACLs are not.
# Usage: ./test4-b4-nacl.sh
set -euo pipefail
cd "$(dirname "$0")"

VPC=$(terraform -chdir=../terraform/aws/network output -raw vpc_id)
NACL=$(aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" "Name=default,Values=true" \
       --query 'NetworkAcls[0].NetworkAclId' --output text)
read -r EKS_IP AZ_IP <<<"$(./netshoot.sh)"
EKS="kubectl --context cloudbridge-eks exec nsh --"
AKS="kubectl --context cloudbridge-aks exec nsh --"
OUT=../docs/runs/test4-b4.txt
RULE=50
mkdir -p ../docs/runs
trap 'aws ec2 delete-network-acl-entry --network-acl-id $NACL --ingress --rule-number $RULE 2>/dev/null' EXIT

# A TCP listener on the EKS pod (port 9090, below the denied range) for the Azure -> AWS check
# (pkill -x matches the process name only; "pkill -f <pattern>" would match this shell's own
# command line and kill it before the listener starts)
$EKS sh -c 'pkill -x nc; nohup nc -lk -p 9090 >/dev/null 2>&1 &' || true
sleep 2

# Seconds until AWS -> Azure TCP reaches the wanted state (fail|ok), polling every 2 s.
# NACL changes are not instant and the delay varies, so measure it instead of guessing a sleep.
until_state() {
  local want=$1 t0 now
  t0=$(date +%s)
  while :; do
    if $EKS nc -z -w 2 "$AZ_IP" 5201 >/dev/null 2>&1; then now=ok; else now=fail; fi
    [ "$now" = "$want" ] && { echo "$(( $(date +%s) - t0 ))"; return; }
    [ $(( $(date +%s) - t0 )) -gt 180 ] && { echo "timeout"; return; }
    sleep 2
  done
}

check() {
  printf "AWS -> Azure TCP 5201 : "; $EKS nc -z -w 3 "$AZ_IP" 5201 >/dev/null 2>&1 && echo OK || echo FAIL
  printf "Azure -> AWS TCP 9090 : "; $AKS nc -z -w 3 "$EKS_IP" 9090 >/dev/null 2>&1 && echo OK || echo FAIL
  printf "AWS -> Azure ping     : "; $EKS ping -c 2 -W 1 "$AZ_IP" >/dev/null 2>&1 && echo OK || echo FAIL
}

{
  echo "== Baseline"; check

  echo; echo "== Break: NACL $NACL rule $RULE: DENY inbound TCP 32768-65535 from the Azure VNet"
  aws ec2 create-network-acl-entry --network-acl-id "$NACL" --ingress --rule-number $RULE \
    --protocol tcp --port-range From=32768,To=65535 --cidr-block 10.20.0.0/16 --rule-action deny
  echo "enforced after: $(until_state fail) s"
  check
  echo "-- NACL inbound rules:"
  aws ec2 describe-network-acls --network-acl-ids "$NACL" \
    --query "NetworkAcls[0].Entries[?Egress==\`false\`].[RuleNumber,RuleAction,Protocol,CidrBlock,PortRange.From,PortRange.To]" --output text

  echo; echo "== Fix: remove the rule"
  aws ec2 delete-network-acl-entry --network-acl-id "$NACL" --ingress --rule-number $RULE
  echo "removed after: $(until_state ok) s"
  check
} 2>&1 | tee "$OUT"
