#!/usr/bin/env bash
# Test 2: AWS region loss = the app AND the private link at once (v1 C2, now with the
# 4-tunnel active-active VPN).
#   app:          scale EKS frontend and backend to 0 -> the ALB /health fails
#   private link: a wrong shared key on all 4 Azure connections -> IKE fails -> all 4 tunnels
#                 and BGP sessions drop
# Shows: (1) Route 53 and Traffic Manager both move users to Azure, and the DNS path never
# depends on the VPN; (2) BGP withdraws the routes on both sides (Azure learned routes, the
# TGW inspection table); (3) cloudbridge-vpn-link-down (CloudWatch) and cloudbridge-bgp-peer-down
# (Azure Monitor) fire. Restore is timed separately.
#
#   ./test2-region-loss.sh break      steady AWS check, probe on, break both, watch (~12 min)
#   ./test2-region-loss.sh restore    prints the terraform drift fix for you to run (it puts the
#                                     PSKs back), waits for Enter, scales the app back, times
#                                     tunnel + BGP recovery and the failback (~10 min)
#   ./test2-region-loss.sh status     one read-only state sample
#
# The probe runs on this laptop between the two subcommands: 1 request/s, a fresh DNS lookup
# each time through a public resolver (RESOLVER, default 1.1.1.1) as a user's resolver would,
# plus a direct query to one Route 53 server and to Traffic Manager each second, so each
# provider's switch is timed on its own. The real PSKs are never read: only narrow --query
# fields are requested, and the wrong key is a fixed test string. Nothing here runs terraform.
# Results go to docs/runs/test2-*.
set -euo pipefail
cd "$(dirname "$0")"

DOMAIN=jeevs.click
APP=app.$DOMAIN
RG=cloudbridge-rg
GW=cloudbridge-vpngw
TUNNELS="c0-t1 c0-t2 c1-t1 c1-t2"
WRONG_KEY=cbWrongKeyForTest2   # not a secret: it only has to differ from the real PSK
RESOLVER=${RESOLVER:-1.1.1.1}
BASELINE=${BASELINE:-30}
BROKEN=${BROKEN:-720}          # s to watch after the break (CloudWatch VPN alarms use 5-min periods)
RECOVERY=${RECOVERY:-600}      # s to watch after the app is scaled back
OUT=../docs/runs/test2
K="kubectl --context cloudbridge-eks -n cloudbridge"
AWS="aws --region us-east-2"
MB_REPORT=../docs/mindbridge/whatif-report.json
mkdir -p ../docs/runs

# ==================== helpers ====================

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
iso_ms() { python3 -c 'import datetime as d,sys; print(d.datetime.fromtimestamp(int(sys.argv[1])/1000, d.timezone.utc).strftime("%H:%M:%S"))' "$1"; }

pause() {  # print the command the user runs, wait for Enter
  echo
  echo "---------------------------------------------------------------------------"
  echo "YOU RUN (another terminal, from the repo root):"
  echo
  echo "  $1"
  echo
  echo "---------------------------------------------------------------------------"
  read -r -p "Press Enter once the apply has finished... " _
}

fw_public_ip() { az network public-ip show -g "$RG" -n cloudbridge-fw --query ipAddress -o tsv; }
tm_fqdn() { az network traffic-manager profile list -g "$RG" --query '[0].dnsConfig.fqdn' -o tsv 2>/dev/null; }
first_r53_ns() {
  local zid
  zid=$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" \
    --query "HostedZones[?Name=='$DOMAIN.' && Config.PrivateZone==\`false\`].Id | [0]" --output text | sed 's#/hostedzone/##')
  aws route53 get-hosted-zone --id "$zid" --query 'DelegationSet.NameServers[0]' --output text
}

# Tunnel key (c0-t1 ...) <-> AWS outside IP, read from the Azure local network gateways
MAP=""; BREAK=""; wpid=""
load_map() {
  local t ip
  MAP=""
  for t in $TUNNELS; do
    ip=$(az network local-gateway show -g "$RG" -n "cloudbridge-lng-aws-$t" --query gatewayIpAddress -o tsv)
    MAP="$MAP$t $ip"$'\n'
  done
}
key_for_ip() { awk -v ip="$1" '$2 == ip { print $1 }' <<<"$MAP"; }

TGW_RT=""
load_tgw_rt() {
  TGW_RT=$($AWS ec2 describe-transit-gateway-route-tables \
    --filters "Name=tag:Name,Values=cloudbridge-tgw-rt-inspection" "Name=state,Values=available" \
    --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' --output text)
}
AZ_RULE_ID=""
load_alert_rule() {
  AZ_RULE_ID=$(az monitor metrics alert show -g "$RG" -n cloudbridge-bgp-peer-down --query id -o tsv 2>/dev/null || true)
}

# ---- state, each piece one narrow read-only call ----
# describe-vpn-connections also returns the tunnel options with the PSKs: only telemetry is queried
s_aws() {  # "c0-t1=UP/2 ..." (status / accepted BGP routes)
  local ip st n
  $AWS ec2 describe-vpn-connections \
    --filters "Name=tag:Name,Values=cloudbridge-vpn-azure-c0,cloudbridge-vpn-azure-c1" "Name=state,Values=available" \
    --query 'VpnConnections[].VgwTelemetry[].[OutsideIpAddress,Status,AcceptedRouteCount]' --output text 2>/dev/null |
    while read -r ip st n; do echo "$(key_for_ip "$ip")=$st/$n"; done | sort | tr '\n' ' '
}
s_conns() {
  az network vpn-connection list -g "$RG" --query "[].[name,connectionStatus]" -o tsv 2>/dev/null |
    sed 's/^cloudbridge-conn-aws-//' | sort | awk '{ printf "%s=%s ", $1, $2 }'
}
s_peers() {
  az network vnet-gateway list-bgp-peer-status -g "$RG" -n "$GW" \
    --query "value[].[neighbor,state]" -o tsv 2>/dev/null | sort -u | awk '{ printf "%s=%s ", $1, $2 }'
}
s_learned() {  # routes Azure learned from AWS over eBGP
  az network vnet-gateway list-learned-routes -g "$RG" -n "$GW" \
    --query "length(value[?origin=='EBgp'])" -o tsv 2>/dev/null || echo "?"
}
s_tgw() {  # Azure prefixes in the TGW inspection table: "10.20.0.0/20x2;10.20.240.0/22x2" or none
  local r
  r=$($AWS ec2 search-transit-gateway-routes --transit-gateway-route-table-id "$TGW_RT" \
    --filters "Name=state,Values=active" \
    --query "Routes[?starts_with(DestinationCidrBlock, '10.20.')].[DestinationCidrBlock, length(TransitGatewayAttachments || \`[]\`)]" \
    --output text 2>/dev/null | sort | awk '{ printf "%s%sx%s", (NR > 1 ? ";" : ""), $1, $2 }')
  echo "${r:-none}"
}
s_alarms() {  # "link-down=OK c0-down=OK c0-degraded=OK ..."
  $AWS cloudwatch describe-alarms --alarm-name-prefix cloudbridge-vpn \
    --query 'MetricAlarms[].[AlarmName,StateValue]' --output text 2>/dev/null |
    sed 's/^cloudbridge-vpn-//' | sort | awk '{ printf "%s=%s ", $1, $2 }'
}
az_alerts_url() {
  local q
  q=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$AZ_RULE_ID")
  echo "/subscriptions/{subscriptionId}/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=1d&alertRule=$q"
}
s_az_alert() {  # latest alert instance of cloudbridge-bgp-peer-down: "Fired@2026-..." / "Resolved@..." / none
  [ -n "$AZ_RULE_ID" ] || { echo "no-rule"; return; }
  az rest --method get --url "$(az_alerts_url)" \
    --query "value[].properties.essentials.[startDateTime, monitorCondition]" -o tsv 2>/dev/null |
    sort | tail -n 1 | awk '{ print ($2 == "" ? "none" : $2 "@" $1) }' | grep . || echo none
}

STATE_HDR="epoch_ms,phase,aws_tunnels,az_connections,bgp_peers,az_learned_ebgp,tgw_azure_routes,cw_alarms,az_bgp_alert"
snapshot() {  # one CSV line; the slow Azure calls (10-30 s each) run in parallel
  local t d
  t=$(now_ms); d=$(mktemp -d)
  s_aws > "$d/aws" & s_conns > "$d/conns" & s_peers > "$d/peers" & s_learned > "$d/learned" &
  s_tgw > "$d/tgw" & s_alarms > "$d/alarms" & s_az_alert > "$d/alert" &
  wait
  echo "$t,$1,$(cat "$d/aws"),$(cat "$d/conns"),$(cat "$d/peers"),$(tr -d '\n' < "$d/learned"),$(cat "$d/tgw"),$(cat "$d/alarms"),$(cat "$d/alert")"
  rm -rf "$d"
}
watch_state() {  # $1 phase, $2 seconds, $3 csv
  local end=$(( $(date +%s) + $2 )) t0
  while [ "$(date +%s)" -lt "$end" ]; do
    t0=$(date +%s)
    snapshot "$1" | tee -a "$3"
    sleep $(( 15 - ($(date +%s) - t0) > 0 ? 15 - ($(date +%s) - t0) : 0 ))
  done
}

# 1 req/s, fresh DNS each time through $RESOLVER (no OS cache), then HTTP to that address.
# r53 / tm: what one Route 53 server and Traffic Manager answer right now (no cache at all).
probe_loop() {  # $1 fw public ip, $2 route 53 ns, $3 tm fqdn, $4 tm ns
  set +e
  trap '' HUP   # keeps running between break and restore even if the terminal goes away
  local start ip dns_ms body code secs cloud ms r53 tm a
  echo "epoch_ms,http_code,cloud,latency_ms,ip,dns_ms,r53,tm"
  while :; do
    start=$(now_ms)
    ip=$(dig +short +time=1 +tries=1 "$APP" A @"$RESOLVER" 2>/dev/null | grep -E '^[0-9.]+$' | tail -n 1)
    dns_ms=$(( $(now_ms) - start ))
    code=000; cloud=none; ms=0
    if [ -n "$ip" ]; then
      body=$(curl -s --max-time 2 --resolve "$APP:80:$ip" -w '\n%{http_code} %{time_total}' "http://$APP/" 2>/dev/null)
      read -r code secs <<<"$(tail -n1 <<<"$body")"
      cloud=$(head -n1 <<<"$body" | sed -n 's/.*"cloud":"\([a-z]*\)".*/\1/p')
      ms=$(awk -v s="${secs:-0}" 'BEGIN { printf "%d", s * 1000 }')
    fi
    a=$(dig +short +norecurse +time=1 +tries=1 "$APP" A @"$2" 2>/dev/null)
    if grep -qx "$1" <<<"$a"; then r53=azure; elif [ -n "$a" ]; then r53=aws; else r53=none; fi
    a=$(dig +short +norecurse +time=1 +tries=1 "$3" @"$4" 2>/dev/null)
    # TM answers the Azure endpoint as a CNAME to its FQDN (*.cloudapp.azure.com), not the IP
    if grep -qx "$1" <<<"$a" || grep -q 'cloudapp\.azure\.com' <<<"$a"; then tm=azure; elif grep -q 'elb\.amazonaws\.com' <<<"$a"; then tm=aws; else tm=none; fi
    echo "${start},${code:-000},${cloud:-none},${ms},${ip:--},${dns_ms},${r53},${tm}"
    sleep "$(awk -v ms="$(( $(now_ms) - start ))" 'BEGIN { s = (1000 - ms) / 1000; print (s > 0 ? s : 0) }')"
  done
}

save_prediction() {  # $1 out file, $2.. components
  local out=$1; shift
  if [ "${MB_REFRESH:-0}" = 1 ]; then (cd ../tools && python3 -m mindbridge whatif --top 0 >/dev/null); fi
  [ -f "$MB_REPORT" ] || { echo "  (no $MB_REPORT: run 'cd tools && python3 -m mindbridge whatif')" >&2; return 0; }
  python3 - "$MB_REPORT" "$out" "$@" <<'PY'
import json, os, sys, time
rep_path, out, comps = sys.argv[1], sys.argv[2], sys.argv[3:]
rep = json.load(open(rep_path))
rows = {r["component"]: r for r in rep["rows"]}
sel = {"saved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
       "report": os.path.relpath(rep_path, os.path.dirname(out)),
       "report_mtime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(os.path.getmtime(rep_path))),
       "method": rep.get("method"),
       "note": "The what-if sweep is N-1 (one component at a time). Test 2 removes the app and all 4 tunnels "
               "together, so compare each row with its part of the result, not with the combined outage.",
       "components": {c: rows.get(c) for c in comps}}
json.dump(sel, open(out, "w"), indent=1)
print(f"== MindBridge AI prediction (what-if, N-1) saved to {out}")
for c in comps:
    r = rows.get(c)
    if not r:
        print(f"  {c:22} not in the report")
        continue
    rec = r.get("recovery_s")
    print(f"  {c:22} {r['status']:8} worst={r['worst_status']:9} recovery={r['recovery']}"
          f"{f' ~{rec:g} s' if rec is not None else ''}  {r['summary']}")
PY
}

steady_aws() {  # 10 AWS answers in a row, resolving fresh each time
  local ok=0 ip body
  echo "waiting for steady AWS traffic (10 in a row through $RESOLVER)..."
  until [ "$ok" -ge 10 ]; do
    ip=$(dig +short +time=1 +tries=1 "$APP" A @"$RESOLVER" | grep -E '^[0-9.]+$' | tail -n 1 || true)
    body=""
    [ -n "$ip" ] && body=$(curl -s --max-time 2 --resolve "$APP:80:$ip" "http://$APP/" || true)
    case "$body" in *'"cloud":"aws"'*) ok=$((ok + 1)) ;; *) ok=0 ;; esac
    sleep 1
  done
}

probe_running() { [ -f "$OUT.probe.pid" ] && kill -0 "$(cat "$OUT.probe.pid")" 2>/dev/null; }

# ==================== subcommands ====================

cmd_break() {
  local fwip r53ns tmf tmns fr br t pids BREAK_DONE   # BREAK: global (EXIT trap)
  load_map; load_tgw_rt; load_alert_rule
  fwip=$(fw_public_ip); r53ns=$(first_r53_ns); tmf=$(tm_fqdn)
  tmns=$(dig +short NS trafficmanager.net @1.1.1.1 | sed -n 1p)
  [ -n "$tmf" ] || { echo "no Traffic Manager profile in $RG: apply global/dns first" >&2; exit 1; }
  fr=$($K get deploy frontend -o jsonpath='{.spec.replicas}'); br=$($K get deploy backend -o jsonpath='{.spec.replicas}')
  echo "Azure fw $fwip  Route 53 server $r53ns  Traffic Manager $tmf @$tmns  replicas frontend=$fr backend=$br"
  probe_running && { echo "a probe is already running (pid $(cat "$OUT.probe.pid")): run restore first, or kill it" >&2; exit 1; }

  steady_aws
  echo "$STATE_HDR" > "$OUT-state.csv"
  probe_loop "$fwip" "$r53ns" "$tmf" "$tmns" > "$OUT-probe.csv" &
  echo $! > "$OUT.probe.pid"
  # Before the break: stop the probe if anything fails. After it: leave the probe running for restore.
  trap 'if [ -z "${BREAK:-}" ]; then kill "$(cat "$OUT.probe.pid")" 2>/dev/null; rm -f "$OUT.probe.pid"; else
          echo; echo "STOPPED with the app at 0 and the tunnels broken: run ./test2-region-loss.sh restore"; fi' EXIT

  save_prediction "$OUT-mindbridge.json" aws-vpn-c0 aws-vpn-c1 vpn-c0-t1 vpn-c0-t2 vpn-c1-t1 vpn-c1-t2 \
    aws-alb eks-node-a eks-node-b dns-failover-r53 dns-failover-tm
  echo "baseline ${BASELINE}s..."
  watch_state baseline "$BASELINE" "$OUT-state.csv"

  BREAK=$(now_ms)
  $K scale deploy/frontend deploy/backend --replicas=0 >/dev/null
  pids=""
  for t in $TUNNELS; do   # in parallel, so all 4 drop within seconds of each other
    az network vpn-connection shared-key update -g "$RG" --connection-name "cloudbridge-conn-aws-$t" \
      --value "$WRONG_KEY" -o none &
    pids="$pids $!"
  done
  for t in $pids; do wait "$t" || echo "  a shared-key update failed (pid $t): check the 4 connections" >&2; done
  BREAK_DONE=$(now_ms)
  {
    echo "break=$BREAK"; echo "break_done=$BREAK_DONE"; echo "replicas_frontend=${fr:-3}"; echo "replicas_backend=${br:-3}"
    echo "fw_public_ip=$fwip"; echo "resolver=$RESOLVER"; echo "r53_ns=$r53ns"; echo "tm_fqdn=$tmf"
  } > "$OUT.meta"
  echo "$(iso_ms "$BREAK") app scaled to 0 + wrong key on 4 connections (took $(( (BREAK_DONE - BREAK) / 1000 ))s); watching ${BROKEN}s..."
  watch_state broken "$BROKEN" "$OUT-state.csv"
  trap - EXIT

  analyze_state > "$OUT-break.txt"
  cat "$OUT-break.txt"
  echo
  echo "The probe keeps running (pid $(cat "$OUT.probe.pid")). NEXT: ./test2-region-loss.sh restore"
}

cmd_restore() {
  local FIXED RESTORE fr br   # wpid: global (EXIT trap)
  [ -f "$OUT.meta" ] || { echo "no $OUT.meta: run break first" >&2; exit 1; }
  probe_running || echo "WARNING: the probe is not running; failback can't be timed from the probe" >&2
  load_map; load_tgw_rt; load_alert_rule
  fr=$(sed -n 's/^replicas_frontend=//p' "$OUT.meta"); br=$(sed -n 's/^replicas_backend=//p' "$OUT.meta")

  # Sample while the apply runs, so tunnel recovery shows up even if it finishes before Enter
  ( set +e; while :; do snapshot psk-fix >> "$OUT-state.csv"; sleep 10; done ) &
  wpid=$!
  trap 'kill $wpid 2>/dev/null' EXIT
  echo "$(iso_ms "$(now_ms)") sampling tunnel/BGP state in the background"
  pause "cd terraform/connectivity/vpn && terraform plan -out=restore.tfplan && terraform apply restore.tfplan   # the plan shows shared_key drift on the 4 connections (values hidden); the apply puts the PSKs back"
  FIXED=$(now_ms)
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  trap - EXIT
  echo "psk_fixed=$FIXED" >> "$OUT.meta"

  RESTORE=$(now_ms)
  $K scale deploy/frontend --replicas="${fr:-3}" >/dev/null
  $K scale deploy/backend --replicas="${br:-3}" >/dev/null
  echo "restore=$RESTORE" >> "$OUT.meta"
  echo "$(iso_ms "$RESTORE") app scaled back (frontend=${fr:-3} backend=${br:-3}); watching ${RECOVERY}s..."
  watch_state restored "$RECOVERY" "$OUT-state.csv"

  if probe_running; then kill "$(cat "$OUT.probe.pid")" 2>/dev/null || true; fi
  rm -f "$OUT.probe.pid"
  {
    analyze_state
    echo
    echo "== Users (probe: 1 req/s, fresh DNS through $(sed -n 's/^resolver=//p' "$OUT.meta"))"
    python3 archive/v1/analyze.py "$OUT-probe.csv" "$(sed -n 's/^break=//p' "$OUT.meta")" "$RESTORE"
    analyze_providers "$RESTORE"
    echo
    history_since "$(sed -n 's/^break=//p' "$OUT.meta")"
  } > "$OUT.txt"
  cat "$OUT.txt"
  echo "saved: $OUT.txt $OUT-break.txt $OUT-probe.csv $OUT-state.csv $OUT.meta $OUT-mindbridge.json"
}

# Each provider's own switch, from the direct (uncached) queries in the probe
analyze_providers() {  # [$1 restore ms]
  python3 - "$OUT-probe.csv" "$(sed -n 's/^break=//p' "$OUT.meta")" "${1:-0}" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
brk, rst = int(sys.argv[2]), int(sys.argv[3])
for r in rows: r["t"] = int(r["epoch_ms"])
print("== Each provider on its own (direct query each second, no resolver cache)")
for col, name in (("r53", "Route 53 (failover records)"), ("tm", "Traffic Manager (behind Azure DNS)")):
    a = next((r for r in rows if brk <= r["t"] and (not rst or r["t"] < rst) and r[col] == "azure"), None)
    print(f"  {name:36} answers Azure at break + {(a['t'] - brk) / 1000:.1f} s" if a else f"  {name:36} never answered Azure")
    if rst:
        b = next((r for r in rows if r["t"] >= rst and r[col] == "aws"), None)
        print(f"  {name:36} answers AWS again at restore + {(b['t'] - rst) / 1000:.1f} s" if b else f"  {name:36} not back on AWS yet")
PY
}

# Timeline of the state samples: when each part of the private link went down and came back
analyze_state() {
  python3 - "$OUT-state.csv" "$OUT.meta" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
meta = dict(l.strip().split("=", 1) for l in open(sys.argv[2]) if "=" in l)
brk = int(meta["break"]); fixed = int(meta.get("psk_fixed", 0)); rst = int(meta.get("restore", 0))
for r in rows: r["t"] = int(r["epoch_ms"])
def kv(s): return dict(p.split("=", 1) for p in s.split() if "=" in p)
def ups(r): return sum(v.startswith("UP") for v in kv(r["aws_tunnels"]).values())
def conn(r): return sum(v == "Connected" for v in kv(r["az_connections"]).values())
def peers(r): return sum(v == "Connected" for v in kv(r["bgp_peers"]).values())
def learned(r):
    try: return int(r["az_learned_ebgp"])
    except ValueError: return -1
base = [r for r in rows if r["phase"] == "baseline"]
b = base[-1] if base else None
if b:
    print(f"baseline: AWS tunnels UP {ups(b)}/4, Azure connections {conn(b)}/4, BGP peers {peers(b)}/4, "
          f"Azure learned eBGP routes {learned(b)}, TGW inspection table {b['tgw_azure_routes']}")
def first(pred, since, until=None):
    return next((r for r in rows if r["t"] >= since and (until is None or r["t"] < until) and pred(r)), None)
def show(label, r, ref, refname):
    print(f"  {label:46} {('%s + %.0f s' % (refname, (r['t'] - ref) / 1000)) if r else 'not seen'}")
end = fixed or None
print("== After the break (samples every ~15 s; each value is the sample's start time)")
show("first AWS tunnel DOWN", first(lambda r: kv(r["aws_tunnels"]) and ups(r) < 4, brk, end), brk, "break")
show("all 4 AWS tunnels DOWN", first(lambda r: kv(r["aws_tunnels"]) and ups(r) == 0, brk, end), brk, "break")
show("all 4 Azure connections not Connected", first(lambda r: kv(r["az_connections"]) and conn(r) == 0, brk, end), brk, "break")
show("all 4 BGP peers down (Azure)", first(lambda r: kv(r["bgp_peers"]) and peers(r) == 0, brk, end), brk, "break")
show("Azure withdrew AWS routes (learned eBGP = 0)", first(lambda r: learned(r) == 0, brk, end), brk, "break")
show("TGW withdrew Azure routes (inspection table)", first(lambda r: r["tgw_azure_routes"] == "none", brk, end), brk, "break")
show("cloudbridge-vpn-link-down = ALARM", first(lambda r: "link-down=ALARM" in r["cw_alarms"], brk, end), brk, "break")
show("cloudbridge-bgp-peer-down Fired (Azure)", first(lambda r: r["az_bgp_alert"].startswith("Fired"), brk, end), brk, "break")
if fixed:
    print("== After the PSK fix (ref = when you pressed Enter, i.e. the apply had finished; negative = during the apply)")
    since = brk + 60000
    for label, pred in (("all 4 AWS tunnels UP", lambda r: ups(r) == 4),
                        ("all 4 BGP peers Connected (Azure)", lambda r: peers(r) == 4),
                        ("Azure learned eBGP routes back to baseline", lambda r: b and learned(r) >= learned(b)),
                        ("TGW inspection table back to baseline", lambda r: b and r["tgw_azure_routes"] == b["tgw_azure_routes"]),
                        ("cloudbridge-vpn-link-down = OK", lambda r: "link-down=OK" in r["cw_alarms"]),
                        ("cloudbridge-bgp-peer-down Resolved", lambda r: r["az_bgp_alert"].startswith("Resolved"))):
        r = next((r for r in rows if r["t"] >= since and r["phase"] != "broken" and pred(r)), None)
        show(label, r, fixed, "fixed")
PY
}

# Exact times from the providers' own logs (read-only)
history_since() {  # $1 break ms
  local start
  start=$(python3 -c 'import datetime as d,sys; print((d.datetime.fromtimestamp(int(sys.argv[1])/1000, d.timezone.utc)-d.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1")
  echo "== CloudWatch alarm history since $start (exact state-change times)"
  $AWS cloudwatch describe-alarm-history --history-item-type StateUpdate --start-date "$start" \
    --query "AlarmHistoryItems[?starts_with(AlarmName, 'cloudbridge-vpn')].[Timestamp, AlarmName, HistorySummary]" \
    --output text | sort | sed 's/^/  /' || true
  echo "== Azure Monitor alert cloudbridge-bgp-peer-down"
  if [ -n "$AZ_RULE_ID" ]; then
    az rest --method get --url "$(az_alerts_url)" \
      --query "value[].properties.essentials.[startDateTime, monitorCondition, monitorConditionResolvedDateTime]" -o tsv 2>/dev/null |
      sort | sed 's/^/  fired /' || true
  fi
  echo "== Azure Activity Log: shared-key writes (the break, then the terraform fix)"
  az monitor activity-log list -g "$RG" --start-time "$start" \
    --query "[?contains(operationName.value, 'sharedkey') || contains(operationName.value, 'sharedKey')].[eventTimestamp, status.value, resourceId]" \
    -o tsv 2>/dev/null | awk -F'\t' '{ sub(/.*\/connections\//, "", $3); sub(/\/.*/, "", $3); print "  " $1, $2, $3 }' | sort || true
}

cmd_status() {
  load_map; load_tgw_rt; load_alert_rule
  echo "$STATE_HDR"; snapshot status
}

case "${1:-}" in
  break)   cmd_break ;;
  restore) cmd_restore ;;
  status)  cmd_status ;;
  *) echo "usage: $0 break|restore|status" >&2; exit 1 ;;
esac
