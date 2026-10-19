#!/usr/bin/env bash
# Point (or break) the private DNS name the AWS frontend uses to reach its backend.
#   ./backend-dns.sh set     -> backend.cloudbridge.internal CNAME <internal NLB>
#   ./backend-dns.sh delete  -> record removed: NXDOMAIN, like the Oct 2025 empty record
set -euo pipefail

NAME="backend.cloudbridge.internal"
TTL=30  # Short TTL so both breaking and restoring take effect within ~30 s

ZONE_ID=$(terraform -chdir="$(dirname "$0")/../terraform/aws/eks" output -raw internal_zone_id)
NLB=$(kubectl --context cloudbridge-eks -n cloudbridge get svc backend \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

change() {
  aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "{
    \"Changes\": [{\"Action\": \"$1\", \"ResourceRecordSet\": {
      \"Name\": \"$NAME\", \"Type\": \"CNAME\", \"TTL\": $TTL,
      \"ResourceRecords\": [{\"Value\": \"$NLB\"}]}}]}" \
    --query 'ChangeInfo.Status' --output text
}

case "${1:-}" in
  set)    change UPSERT; echo "$NAME -> $NLB" ;;
  delete) change DELETE; echo "$NAME deleted (frontends will fail /health within ~TTL)" ;;
  *)      echo "usage: $0 set|delete" >&2; exit 1 ;;
esac
