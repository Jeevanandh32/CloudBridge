#!/usr/bin/env bash
# Build the app image once, push it to both registries, and deploy it to both clusters.
# The manifests say "REGISTRY/cloudbridge-app"; the real registry (ECR URL / ACR login server)
# is read from Terraform outputs here, so no account or subscription IDs are committed.
#
#   ./deploy.sh                     = ./deploy.sh all
#   ./deploy.sh all                 build + push to ECR and ACR, deploy aws + azure, EKS CoreDNS
#   ./deploy.sh aws | azure         build + push to that cloud's registry, deploy that overlay
#   ./deploy.sh aws-tuned           v1 only overlay (still renders on top of aws)
#   ./deploy.sh coredns             Fallback only: Terraform sets CoreDNS forwarding via the EKS add-on
#   ./deploy.sh <target> --dry-run  render only: print the manifests, no build, push or apply
#   ./deploy.sh <target> --no-build skip docker build/push (image already in the registry)
#
# Env: TAG (default v1), REGISTRY_AWS / REGISTRY_AZURE (registry/repo without tag, to work
# without Terraform state).
# Layers it reads: terraform/aws/eks (ecr_repository_url), terraform/azure/aks
# (acr_login_server), terraform/azure/hub (fw_public_ip, for the printed URL).
set -euo pipefail
cd "$(dirname "$0")"

TARGET="${1:-all}"
shift || true
DRY="" BUILD=1
for a in "$@"; do
  case "$a" in
    --dry-run)  DRY=1; BUILD="" ;;
    --no-build) BUILD="" ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done
TAG="${TAG:-v1}"
TF=../terraform
IMG=cloudbridge-app

reg_aws() {
  [ -n "${REGISTRY_AWS:-}" ] && { echo "$REGISTRY_AWS"; return; }
  terraform -chdir=$TF/aws/eks output -raw ecr_repository_url 2>/dev/null ||
    { [ -n "$DRY" ] && echo "REGISTRY/$IMG" && return; echo "no ecr_repository_url: is aws/eks applied?" >&2; return 1; }
}
reg_azure() {
  [ -n "${REGISTRY_AZURE:-}" ] && { echo "$REGISTRY_AZURE"; return; }
  local s
  s=$(terraform -chdir=$TF/azure/aks output -raw acr_login_server 2>/dev/null) && { echo "$s/$IMG"; return; }
  [ -n "$DRY" ] && { echo "REGISTRY/$IMG"; return; }
  echo "no acr_login_server: is azure/aks applied?" >&2; return 1
}

BUILT=""
build() {  # once per run; both clusters run amd64 nodes (t3.medium, B2als_v2)
  [ -n "$BUILT" ] && return
  echo "== docker build $IMG:$TAG (linux/amd64)"
  docker build --platform linux/amd64 -t "$IMG:$TAG" ../app
  BUILT=1
}
push_aws() {
  local reg=$1
  build
  echo "== push to ECR ${reg%%/*}"
  # The password goes straight from the CLI into docker; it is never printed
  aws ecr get-login-password --region us-east-2 | docker login --username AWS --password-stdin "${reg%%/*}" >/dev/null
  docker tag "$IMG:$TAG" "$reg:$TAG"
  docker push "$reg:$TAG"
}
push_azure() {
  local reg=$1 acr
  build
  acr=${reg%%/*}
  echo "== push to ACR $acr"
  az acr login -n "${acr%%.*}" >/dev/null
  docker tag "$IMG:$TAG" "$reg:$TAG"
  docker push "$reg:$TAG"
}

render() {  # $1 overlay, $2 registry/repo
  kubectl kustomize "overlays/$1" | sed "s|REGISTRY/$IMG:v1|$2:$TAG|g"
}

deploy() {  # $1 overlay, $2 context, $3 registry/repo
  local m
  m=$(render "$1" "$3")
  if [ -n "$DRY" ]; then echo "$m"; return; fi
  echo "== apply overlays/$1 -> $2"
  echo "$m" | kubectl --context "$2" apply -f -
  kubectl --context "$2" -n cloudbridge rollout status deploy/backend --timeout=300s
  kubectl --context "$2" -n cloudbridge rollout status deploy/frontend --timeout=300s
}

do_aws() {  # $1 overlay (aws | aws-tuned)
  local reg
  reg=$(reg_aws)
  [ -n "$BUILD" ] && push_aws "$reg"
  deploy "$1" cloudbridge-eks "$reg"
  [ -n "$DRY" ] && return
  local host="" i
  for i in $(seq 1 30); do
    host=$(kubectl --context cloudbridge-eks -n cloudbridge get ingress frontend \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    [ -n "$host" ] && break
    sleep 10
  done
  echo "ALB: http://${host:-<not ready yet: kubectl -n cloudbridge get ingress frontend>}/health"
  echo "     (a new ALB takes 2-3 min before it answers)"
}

do_azure() {
  local reg ip
  reg=$(reg_azure)
  [ -n "$BUILD" ] && push_azure "$reg"
  deploy azure cloudbridge-aks "$reg"
  [ -n "$DRY" ] && return
  kubectl --context cloudbridge-aks -n cloudbridge get svc frontend \
    -o custom-columns='SERVICE:.metadata.name,TYPE:.spec.type,ILB:.status.loadBalancer.ingress[0].ip'
  ip=$(terraform -chdir=$TF/azure/hub output -raw fw_public_ip 2>/dev/null || echo '<fw_public_ip>')
  echo "Azure (firewall DNAT -> ILB 10.20.4.10): http://$ip/health"
}

do_coredns() {
  if [ -n "$DRY" ]; then kubectl kustomize coredns-eks; return; fi
  echo "== EKS CoreDNS: forward Azure zones to the AWS firewalls (diff, then apply)"
  kubectl --context cloudbridge-eks diff -k coredns-eks || true   # exit 1 just means "differs"
  kubectl --context cloudbridge-eks apply -k coredns-eks
}

case "$TARGET" in
  all)        do_aws aws; do_azure ;;   # CoreDNS forwarding comes from the EKS add-on (terraform/aws/eks)
  aws)        do_aws aws ;;
  aws-tuned)  do_aws aws-tuned ;;
  azure)      do_azure ;;
  coredns)    do_coredns ;;
  *) echo "usage: $0 [all|aws|aws-tuned|azure|coredns] [--dry-run] [--no-build]" >&2; exit 1 ;;
esac
