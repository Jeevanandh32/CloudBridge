#!/usr/bin/env bash
# Test 2: lose the whole AWS app at once (every frontend and backend pod gone), then bring
# it back. Unlike Test 1, nothing is "half healthy": the ALB has no targets at all.
# Expected: ALB returns 503 -> Route 53 marks AWS unhealthy -> Azure serves; scaling back
# up returns traffic to AWS.
# Usage: ./test2-region-loss.sh <run-number>
set -euo pipefail
cd "$(dirname "$0")"

RUN="${1:?usage: $0 <run-number>}"
OUT="../docs/runs/test2-run${RUN}.csv"
BASELINE=30
OUTAGE=180
RECOVERY=180
K="kubectl --context cloudbridge-eks -n cloudbridge"

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

echo "waiting for steady AWS traffic..."
ok=0
until [ "$ok" -ge 10 ]; do
  if curl -s --max-time 2 http://app.jeevs.click/ | grep -q '"cloud":"aws"'; then ok=$((ok + 1)); else ok=0; fi
  sleep 1
done

mkdir -p ../docs/runs
./probe.sh > "$OUT" &
PROBE=$!
trap 'kill $PROBE 2>/dev/null; $K scale deploy/frontend deploy/backend --replicas=3 >/dev/null' EXIT

echo "baseline ${BASELINE}s..."; sleep "$BASELINE"

BREAK=$(now_ms); $K scale deploy/frontend deploy/backend --replicas=0
echo "outage ${OUTAGE}s..."; sleep "$OUTAGE"

RESTORE=$(now_ms); $K scale deploy/frontend deploy/backend --replicas=3
echo "recovery ${RECOVERY}s..."; sleep "$RECOVERY"

kill $PROBE
echo "break=$BREAK restore=$RESTORE" > "${OUT%.csv}.meta"
python3 analyze.py "$OUT" "$BREAK" "$RESTORE"
