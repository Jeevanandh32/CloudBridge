#!/usr/bin/env bash
# Print the ENIConfigs (one per AZ) built from the terraform/aws/eks outputs:
#   eniconfig_subnets       map AZ -> pod subnet id (empty until aws/spoke-app
#                           enable_secondary_cidr=true AND aws/eks has been re-applied)
#   node_security_group_id  the EKS node security group
# Usage:
#   k8s/eniconfig/render.sh                                   # print
#   k8s/eniconfig/render.sh | kubectl --context cloudbridge-eks apply -f -
set -euo pipefail
cd "$(dirname "$0")"

TF=../../terraform/aws/eks
subnets=$(terraform -chdir="$TF" output -json eniconfig_subnets)
sg=$(terraform -chdir="$TF" output -raw node_security_group_id)

if [ "$(jq 'length' <<<"$subnets")" -eq 0 ]; then
  echo "eniconfig_subnets is empty: apply aws/spoke-app with enable_secondary_cidr=true, then re-apply aws/eks" >&2
  exit 1
fi

first=1
jq -r 'to_entries[] | "\(.key) \(.value)"' <<<"$subnets" | while read -r az subnet; do
  [ $first = 1 ] || echo "---"
  first=0
  sed -e "s|__AZ__|$az|g" -e "s|__SUBNET_ID__|$subnet|g" -e "s|__NODE_SG__|$sg|g" eniconfig.yaml.tmpl | grep -v '^#'
done
