#!/usr/bin/env bash
# Test 1: reproduce the Oct 2025 AWS outage pattern. Every server stays healthy, but the
# DNS name the AWS frontend uses for its dependency stops resolving.
# Expected: AWS /health fails -> Route 53 marks AWS unhealthy -> traffic moves to Azure;
# restoring the record moves traffic back.
# Usage: ./test1-dns-outage.sh <run-number>
set -euo pipefail
cd "$(dirname "$0")"

RUN="${1:?usage: $0 <run-number>}"
OUT="../docs/runs/test1-run${RUN}.csv"
BASELINE=30   # seconds of normal traffic before the break
OUTAGE=180    # how long the record stays deleted
RECOVERY=180  # how long to watch failback

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

# Pre-flight: start only when AWS has served 10 requests in a row, so a previous run's
# recovery can't leak into this one
echo "waiting for steady AWS traffic..."
ok=0
until [ "$ok" -ge 10 ]; do
  if curl -s --max-time 2 http://app.jeevs.click/ | grep -q '"cloud":"aws"'; then ok=$((ok + 1)); else ok=0; fi
  sleep 1
done

mkdir -p ../docs/runs
./probe.sh > "$OUT" &
PROBE=$!
trap 'kill $PROBE 2>/dev/null; ./backend-dns.sh set >/dev/null' EXIT  # always restore

echo "baseline ${BASELINE}s..."; sleep "$BASELINE"

BREAK=$(now_ms); ./backend-dns.sh delete
echo "outage ${OUTAGE}s..."; sleep "$OUTAGE"

RESTORE=$(now_ms); ./backend-dns.sh set
echo "recovery ${RECOVERY}s..."; sleep "$RECOVERY"

kill $PROBE
echo "break=$BREAK restore=$RESTORE" > "${OUT%.csv}.meta"
python3 analyze.py "$OUT" "$BREAK" "$RESTORE"
