#!/usr/bin/env bash
# Test 4 / B5: what 502, 503 and 504 from an ALB actually mean.
#   504  target accepted the request but didn't answer before the ALB's idle timeout
#   502  target answered with something invalid, or reset/closed the connection
#   503  no healthy targets registered
# Temporarily: frontend runs image v2 with ENABLE_FAULTS=true, ALB idle timeout = 5 s.
# Usage: ./test4-b5-lb-errors.sh
set -euo pipefail
cd "$(dirname "$0")"

K="kubectl --context cloudbridge-eks -n cloudbridge"
ECR=$(terraform -chdir=../terraform/aws/eks output -raw ecr_repository_url)
ALB=$($K get ingress frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
OUT=../docs/runs/test4-b5.txt
ATTR="alb.ingress.kubernetes.io/load-balancer-attributes"
mkdir -p ../docs/runs

restore() {
  # The overlay sets idle_timeout=60 explicitly: removing the annotation alone would leave 5 s
  # (the controller never resets attributes whose annotation disappears)
  $K set env deploy/frontend ENABLE_FAULTS- >/dev/null 2>&1 || true
  ../k8s/deploy.sh aws >/dev/null
  $K scale deploy/frontend --replicas=3 >/dev/null
  $K rollout status deploy/frontend --timeout=300s >/dev/null
}
trap restore EXIT

req() {  # $1 = path; prints status, time, and who generated the response
  curl -s -o /dev/null -D /tmp/b5-h.txt -w "%{http_code} in %{time_total}s" --max-time 30 "http://$ALB$1"
  printf "  server: %s\n" "$(grep -i '^server:' /tmp/b5-h.txt | tr -d '\r' | cut -d' ' -f2-)"
}

{
  echo "== Setup: fault endpoints on, ALB idle timeout 5 s"
  $K set image deploy/frontend app="$ECR:v2" >/dev/null
  $K set env deploy/frontend ENABLE_FAULTS=true >/dev/null
  $K annotate ingress frontend "$ATTR=idle_timeout.timeout_seconds=5" --overwrite >/dev/null
  $K rollout status deploy/frontend --timeout=300s >/dev/null
  sleep 45  # ALB registers the new pods and picks up the new idle timeout

  echo; echo "== Normal request";              printf "GET /            -> "; req /
  echo; echo "== 504: slow target (10 s > 5 s idle timeout)"; printf "GET /slow?s=10   -> "; req "/slow?s=10"
  echo; echo "== 502: target dies mid-request"; printf "GET /crash       -> "; req /crash
  sleep 2
  echo "   pod restarts: $($K get pods -l app=frontend -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount} {end}')"
  echo; echo "== 503: no targets (frontend scaled to 0)"
  $K scale deploy/frontend --replicas=0 >/dev/null; sleep 20
  printf "GET /            -> "; req /
} 2>&1 | tee "$OUT"
