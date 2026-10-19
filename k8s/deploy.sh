#!/usr/bin/env bash
# Deploy the app to one cloud. The manifests say "REGISTRY/cloudbridge-app"; the real registry
# (ECR URL / ACR login server) is read from Terraform outputs here, so no account or
# subscription IDs are committed.
#   ./deploy.sh aws | aws-tuned | azure            render + apply
#   ./deploy.sh aws --dry-run                      render only (print the manifests)
#   REGISTRY=<host/path> ./deploy.sh aws --dry-run use a registry without Terraform state
set -euo pipefail
cd "$(dirname "$0")"

OVERLAY="${1:?usage: $0 aws|aws-tuned|azure [--dry-run]}"
DRY="${2:-}"

case "$OVERLAY" in
  aws|aws-tuned)
    CTX=cloudbridge-eks
    REG="${REGISTRY:-$(terraform -chdir=../terraform/aws/eks output -raw ecr_repository_url)}" ;;
  azure)
    CTX=cloudbridge-aks
    REG="${REGISTRY:-$(terraform -chdir=../terraform/azure/aks output -raw acr_login_server)/cloudbridge-app}" ;;
  *) echo "unknown overlay: $OVERLAY" >&2; exit 1 ;;
esac

manifests=$(kubectl kustomize "overlays/$OVERLAY" | sed "s|REGISTRY/cloudbridge-app|$REG|g")

if [ "$DRY" = "--dry-run" ]; then
  echo "$manifests"
else
  echo "$manifests" | kubectl --context "$CTX" apply -f -
fi
