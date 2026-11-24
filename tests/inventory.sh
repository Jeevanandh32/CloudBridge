#!/usr/bin/env bash
# Read-only inventory: everything still running or billable in AWS (us-east-2, us-east-1)
# and Azure. Run it after every destroy; the last line says whether anything is left.
#
# Kept on purpose (listed, not counted): the Terraform state bucket (cloudbridge-tfstate-*)
# and Azure's NetworkWatcher (free, created by Azure per region).
#
# Usage: ./inventory.sh
set -euo pipefail

REGIONS="us-east-2 us-east-1"
FOUND=0
ERRORS=0
KEPT=0
OTHER=0

# $1 label, rest = command printing one line per resource (text/tsv). Empty output = clean.
# Set COUNT=OTHER before a call to count its finds as "not CloudBridge" instead.
check() {
  local label=$1 out n
  shift
  if ! out=$("$@" 2>&1); then
    printf "  %-40s ERROR: %s\n" "$label" "$(head -1 <<<"$out")"
    ERRORS=$((ERRORS + 1))
    return 0
  fi
  out=$(grep -v -e '^None$' -e '^[[:space:]]*$' <<<"$out" || true)
  if [ -z "$out" ]; then
    printf "  %-40s none\n" "$label"
  else
    n=$(wc -l <<<"$out" | tr -d ' ')
    if [ "${COUNT:-}" = OTHER ]; then
      printf "  %-40s %s\n" "$label" "$n (not CloudBridge, check yourself)"
      OTHER=$((OTHER + n))
    else
      printf "  %-40s %s\n" "$label" "$n FOUND"
      FOUND=$((FOUND + n))
    fi
    sed 's/^/      /' <<<"$out"
  fi
}

echo "== AWS account $(aws sts get-caller-identity --query Account --output text)"
for r in $REGIONS; do
  A="aws --region $r"
  echo "-- $r"
  check "EC2 instances (not terminated)" $A ec2 describe-instances \
    --filters "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,Tags[?Key==`Name`]|[0].Value]' --output text
  check "EBS volumes" $A ec2 describe-volumes \
    --query 'Volumes[].[VolumeId,State,Size,Tags[?Key==`Name`]|[0].Value]' --output text
  check "Transit Gateways" $A ec2 describe-transit-gateways \
    --filters "Name=state,Values=pending,available,modifying,deleting" \
    --query 'TransitGateways[].[TransitGatewayId,State,Tags[?Key==`Name`]|[0].Value]' --output text
  check "TGW attachments" $A ec2 describe-transit-gateway-attachments \
    --filters "Name=state,Values=pendingAcceptance,pending,available,modifying,initiating,deleting,failing" \
    --query 'TransitGatewayAttachments[].[TransitGatewayAttachmentId,ResourceType,State,Tags[?Key==`Name`]|[0].Value]' --output text
  # Only id/state/name: the full VPN output contains the tunnel pre-shared keys
  check "VPN connections" $A ec2 describe-vpn-connections \
    --filters "Name=state,Values=pending,available,deleting" \
    --query 'VpnConnections[].[VpnConnectionId,State,Tags[?Key==`Name`]|[0].Value]' --output text
  check "Customer gateways" $A ec2 describe-customer-gateways \
    --filters "Name=state,Values=pending,available,deleting" \
    --query 'CustomerGateways[].[CustomerGatewayId,IpAddress,State,Tags[?Key==`Name`]|[0].Value]' --output text
  check "Elastic IPs" $A ec2 describe-addresses \
    --query 'Addresses[].[PublicIp,AllocationId,AssociationId,Tags[?Key==`Name`]|[0].Value]' --output text
  check "NAT gateways" $A ec2 describe-nat-gateways \
    --filter "Name=state,Values=pending,available,deleting" \
    --query 'NatGateways[].[NatGatewayId,State,VpcId]' --output text
  check "Load balancers (ALB/NLB)" $A elbv2 describe-load-balancers \
    --query 'LoadBalancers[].[LoadBalancerName,Type,State.Code]' --output text
  check "Load balancers (classic)" $A elb describe-load-balancers \
    --query 'LoadBalancerDescriptions[].[LoadBalancerName]' --output text
  check "EKS clusters" $A eks list-clusters --query 'clusters[]' --output text
  check "VPC endpoints" $A ec2 describe-vpc-endpoints \
    --filters "Name=vpc-endpoint-state,Values=pendingAcceptance,pending,available,deleting,failed" \
    --query 'VpcEndpoints[].[VpcEndpointId,VpcEndpointType,ServiceName,State]' --output text
  check "VPCs (non-default)" $A ec2 describe-vpcs --filters "Name=is-default,Values=false" \
    --query 'Vpcs[].[VpcId,CidrBlock,Tags[?Key==`Name`]|[0].Value]' --output text
  check "CloudWatch alarms cloudbridge-*" $A cloudwatch describe-alarms --alarm-name-prefix cloudbridge \
    --query 'MetricAlarms[].[AlarmName,StateValue]' --output text
done

echo "-- global"
check "S3 buckets cloudbridge-* (not state)" aws s3api list-buckets \
  --query "Buckets[?starts_with(Name, 'cloudbridge') && !starts_with(Name, 'cloudbridge-tfstate-')].Name" --output text
check "Route 53 health checks" aws route53 list-health-checks \
  --query 'HealthChecks[].[Id,HealthCheckConfig.Type,HealthCheckConfig.FullyQualifiedDomainName]' --output text
check "Route 53 private zones" aws route53 list-hosted-zones \
  --query 'HostedZones[?Config.PrivateZone].[Id,Name]' --output text
COUNT=OTHER check "Route 53 public zones" aws route53 list-hosted-zones \
  --query 'HostedZones[?Config.PrivateZone==`false`].[Id,Name]' --output text
STATE=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, 'cloudbridge-tfstate-')].Name" --output text 2>/dev/null || true)
if [ -n "$STATE" ] && [ "$STATE" != None ]; then
  printf "  %-40s %s (kept: Terraform state)\n" "State bucket" "$STATE"
  KEPT=$((KEPT + 1))
fi

echo
echo "== Azure subscription $(az account show --query "join(' ', [name, id])" -o tsv)"
# CloudBridge = in cloudbridge-rg or tagged Project=cloudbridge (the VNet flow logs live in NetworkWatcherRG)
CB="(resourceGroup=='cloudbridge-rg' || tags.Project=='cloudbridge')"
check "CloudBridge resources" az resource list \
  --query "[?$CB && type!='Microsoft.Network/networkWatchers'].[type, name, resourceGroup]" -o tsv
check "Public IPs" az network public-ip list --query "[].[name, ipAddress, resourceGroup]" -o tsv
check "Resource groups (excl. NetworkWatcherRG)" az group list \
  --query "[?name!='NetworkWatcherRG'].[name, properties.provisioningState]" -o tsv
COUNT=OTHER check "Other resources in the subscription" az resource list \
  --query "[?!$CB && type!='Microsoft.Network/networkWatchers'].[type, name, resourceGroup]" -o tsv
NW=$(az resource list --resource-type Microsoft.Network/networkWatchers --query "length(@)" -o tsv 2>/dev/null || echo 0)
if [ "${NW:-0}" -gt 0 ]; then
  printf "  %-40s %s (kept: free, managed by Azure)\n" "NetworkWatcher" "$NW"
  KEPT=$((KEPT + 1))
fi

echo
if [ "$ERRORS" -gt 0 ]; then
  echo "INVENTORY INCOMPLETE: $ERRORS check(s) failed (login expired?), $FOUND item(s) found. Fix and rerun."
  exit 2
elif [ "$FOUND" -gt 0 ]; then
  echo "NOT CLEAN: $FOUND billable item(s) still present (see FOUND above). $KEPT kept on purpose, $OTHER not from CloudBridge."
  exit 1
else
  echo "CLEAN: no CloudBridge resources running or billable in either cloud. $KEPT kept on purpose (state bucket, NetworkWatcher).$([ "$OTHER" -gt 0 ] && echo " $OTHER other Azure resource(s) not from CloudBridge are listed above.")"
fi
