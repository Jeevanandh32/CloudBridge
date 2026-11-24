#!/usr/bin/env bash
# Send 1 request/second to the app and log what happened, as CSV:
#   epoch_ms,http_code,cloud,latency_ms
# Each request opens a new connection, so it re-resolves DNS (subject to the OS cache).
# Usage: ./probe.sh [url] > run.csv     (Ctrl+C to stop)
set -uo pipefail

URL="${1:-http://app.jeevs.click/}"
echo "epoch_ms,http_code,cloud,latency_ms"

while true; do
  start=$(python3 -c 'import time; print(int(time.time()*1000))')
  body=$(curl -s --max-time 2 -w '\n%{http_code} %{time_total}' "$URL" 2>/dev/null)
  read -r code secs <<<"$(tail -n1 <<<"$body")"
  cloud=$(head -n1 <<<"$body" | sed -n 's/^{"role":"frontend","cloud":"\([a-z]*\)".*/\1/p')
  ms=$(awk -v s="${secs:-0}" 'BEGIN { printf "%d", s * 1000 }')
  echo "${start},${code:-000},${cloud:-none},${ms}"
  # Keep a steady 1 request/second regardless of how long the request took
  sleep "$(awk -v ms="$ms" 'BEGIN { s = (1000 - ms) / 1000; print (s > 0 ? s : 0) }')"
done
