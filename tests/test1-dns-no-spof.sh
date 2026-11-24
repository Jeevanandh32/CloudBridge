#!/usr/bin/env bash
# Test 1: DNS failover with no single point of failure.
# app.jeevs.click is served by two DNS providers at once: the registrar lists 2 Route 53 and
# 2 Azure DNS name servers. Route 53 answers with its failover records (PRIMARY = ALB alias,
# SECONDARY = Azure firewall public IP); Azure DNS answers with a CNAME to a Traffic Manager
# priority profile (ALB first, Azure firewall IP second). Each provider runs its own health
# checks, so either one can fail over without the other.
#
#   check            read-only: registrar NS, the delegation from the .click TLD servers, the apex
#                    NS each provider returns, app.jeevs.click at every Route 53 and Azure name
#                    server and at public resolvers, Traffic Manager and Route 53 health checks
#   delegation       read-only: exit 0 when every TLD server delegates to the registrar's 4 NS
#                    (use it to wait: the TLD NS TTL is 900 s)
#   provider-loss    on fw-a: unbound (iterator only, no validation, cache flushed before every
#                    query) on 127.0.0.1:5335. 20 timed queries with everything normal, then all
#                    Route 53 name server IPs dropped on fw-a's OUTPUT (nftables), 20 more with a
#                    cold cache and 20 with the server-timeout (infra) cache kept
#   failover-without-route53
#                    Route 53 stays blocked on fw-a. EKS frontend scaled to 0 (the ALB /health
#                    fails). fw-a polls every 2 s: resolve through unbound (fresh cache), curl the
#                    answer's /health. Time to the first "cloud":"azure" answer = failover decided
#                    by Traffic Manager alone. Then the frontend is scaled back (Route 53 still
#                    blocked) and failback is timed; the block is lifted at the end
#   cleanup          lift the block and stop unbound on fw-a
#
# Changes: unbound and a temporary nftables table (inet cbt1) on fw-a, live only (a transient
# systemd unit, nothing in /etc/nftables.conf; a systemd timer deletes the table after
# SAFETY_MIN minutes even if this laptop dies), and the EKS frontend replica count. An EXIT
# trap puts both back. Nothing here runs terraform. Results go to docs/runs/test1-*.
#
# Env: BLOCK_ELB=1 also blocks the name servers of the ALB's own zone (*.elb.amazonaws.com,
#      also Route 53), so the AWS answer itself can't resolve: a total Route 53 outage.
#      BASELINE / OUTAGE / RECOVERY (s) for failover-without-route53; N (queries per phase).
#
# Usage: ./test1-dns-no-spof.sh check|delegation|provider-loss|failover-without-route53|cleanup
set -euo pipefail
cd "$(dirname "$0")"

DOMAIN=jeevs.click
APP=app.$DOMAIN
RG=cloudbridge-rg
K="kubectl --context cloudbridge-eks -n cloudbridge"
PUBLIC_RESOLVERS="1.1.1.1 8.8.8.8 9.9.9.9 208.67.222.222"
N=${N:-20}
BASELINE=${BASELINE:-40}   # s of polling before the break (includes SSM start-up)
OUTAGE=${OUTAGE:-240}      # s the frontend stays at 0
RECOVERY=${RECOVERY:-300}  # s of polling after it is scaled back
SAFETY_MIN=${SAFETY_MIN:-45}
UB_PORT=5335
OUT=../docs/runs/test1
AWS="aws --region us-east-2"
MB_REPORT=../docs/mindbridge/whatif-report.json
mkdir -p ../docs/runs

# ==================== helpers ====================

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
iso_ms() { python3 -c 'import datetime as d,sys; print(d.datetime.fromtimestamp(int(sys.argv[1])/1000, d.timezone.utc).strftime("%H:%M:%S.%f")[:-3])' "$1"; }
wrap() { printf "bash -s <<'CBEOF'\n%s\n%s\nCBEOF\n" "$1" "$2"; }

iid() {
  local id
  id=$($AWS ec2 describe-instances --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -z "$id" ] || [ "$id" = None ]; then echo "no running instance named $1" >&2; return 1; fi
  echo "$id"
}
ssm_send() {  # $1 instance id, $2 vars, $3 body, [$4 timeout s] -> command id
  local params
  params=$(jq -n --arg s "$(wrap "$2" "$3")" --arg t "${4:-600}" '{commands: [$s], executionTimeout: [$t]}')
  $AWS ssm send-command --instance-ids "$1" --document-name AWS-RunShellScript \
    --parameters "$params" --query Command.CommandId --output text
}
ssm_wait() {  # $1 instance id, $2 command id, [$3 max wait s] -> stdout (SSM keeps the first 24,000 chars)
  local st=Pending end=$(( $(date +%s) + ${3:-900} ))
  while [ "$(date +%s)" -lt "$end" ]; do
    st=$($AWS ssm get-command-invocation --instance-id "$1" --command-id "$2" --query Status --output text 2>/dev/null || echo Pending)
    case "$st" in Pending|InProgress|Delayed) sleep 3 ;; *) break ;; esac
  done
  $AWS ssm get-command-invocation --instance-id "$1" --command-id "$2" --query StandardOutputContent --output text 2>/dev/null || true
  [ "$st" = Success ] || echo "  (ssm on $1: $st)" >&2
}
ssm() {
  local cid
  cid=$(ssm_send "$1" "$2" "$3" "${4:-600}")
  ssm_wait "$1" "$cid" "$(( ${4:-600} + 120 ))"
}
b64_decode() { python3 -c 'import base64,gzip,sys; sys.stdout.write(gzip.decompress(base64.b64decode(sys.stdin.read().strip())).decode())'; }

strip_dot() { sed 's/\.$//' | tr 'A-Z' 'a-z'; }
a_of() { dig +short +time=2 +tries=2 A "$1" @1.1.1.1 | grep -E '^[0-9.]+$' || true; }
aaaa_of() { dig +short +time=2 +tries=2 AAAA "$1" @1.1.1.1 | grep ':' || true; }

zone_id() {
  aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" \
    --query "HostedZones[?Name=='$DOMAIN.' && Config.PrivateZone==\`false\`].Id | [0]" --output text | sed 's#/hostedzone/##'
}
r53_ns() {  # the hosted zone's 4 Route 53 name servers
  aws route53 get-hosted-zone --id "$(zone_id)" --query 'DelegationSet.NameServers' --output text | tr '\t' '\n' | strip_dot | sort
}
az_ns() {
  az network dns zone show -g "$RG" -n "$DOMAIN" --query nameServers -o tsv 2>/dev/null | strip_dot | sort
}
registrar_ns() {  # Route 53 Domains lives in us-east-1
  aws route53domains get-domain-detail --region us-east-1 --domain-name "$DOMAIN" \
    --query 'Nameservers[].Name' --output text | tr '\t' '\n' | strip_dot | sort
}
tld_servers() { dig +short NS click. @1.1.1.1 | strip_dot | sort; }
tld_delegation() {  # $1 TLD server -> NS names in its referral
  dig +norecurse +time=3 +tries=2 +noall +authority NS "$DOMAIN" @"$1" | awk '$4 == "NS" { print $5 }' | strip_dot | sort -u
}
tm_profile() { az network traffic-manager profile list -g "$RG" --query '[0].name' -o tsv 2>/dev/null; }
tm_fqdn() { az network traffic-manager profile list -g "$RG" --query '[0].dnsConfig.fqdn' -o tsv 2>/dev/null; }
fw_public_ip() { az network public-ip show -g "$RG" -n cloudbridge-fw --query ipAddress -o tsv; }
alb_dns() { $K get ingress frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; }

# Route 53 health checks for the two endpoints: "aws=16/16 azure=16/16" (checkers reporting Success)
r53_hc_ids() {
  aws route53 list-health-checks --query \
    "HealthChecks[?contains(to_string(HealthCheckConfig.FullyQualifiedDomainName), 'elb.amazonaws.com') || HealthCheckConfig.IPAddress=='$1'].[Id, HealthCheckConfig.FullyQualifiedDomainName || HealthCheckConfig.IPAddress]" \
    --output text
}
r53_hc_summary() {  # $1 fw public ip
  local id tgt ok n
  r53_hc_ids "$1" | while read -r id tgt; do
    read -r ok n < <(aws route53 get-health-check-status --health-check-id "$id" \
      --query 'HealthCheckObservations[].StatusReport.Status' --output text | tr '\t' '\n' |
      awk '/^Success/ { s++ } { n++ } END { print s + 0, n + 0 }')
    case "$tgt" in *elb.amazonaws.com) printf "r53hc_aws=%s/%s " "$ok" "$n" ;; *) printf "r53hc_azure=%s/%s " "$ok" "$n" ;; esac
  done
}
tm_endpoints() {  # "aws-alb=Online azure-fw=Online" (whatever the endpoints are called)
  local p
  p=$(tm_profile)
  [ -n "$p" ] || { echo "tm=none"; return; }
  az network traffic-manager profile show -g "$RG" -n "$p" \
    --query 'endpoints[].[name, endpointMonitorStatus]' -o tsv 2>/dev/null | awk '{ printf "tm_%s=%s ", $1, $2 }'
}
hc_watch() {  # $1 csv, $2 fw ip: every ~10 s, what each provider's health checks think (runs in the background)
  set +e
  echo "epoch_ms,traffic_manager,route53" > "$1"
  while :; do
    echo "$(now_ms),$(tm_endpoints),$(r53_hc_summary "$2")" >> "$1"
    sleep 8
  done
}

# Save MindBridge AI's prediction for the components about to be broken, next to the results
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
       "method": rep.get("method"), "components": {c: rows.get(c) for c in comps}}
json.dump(sel, open(out, "w"), indent=1)
print(f"== MindBridge AI prediction (what-if, N-1) saved to {out}")
for c in comps:
    r = rows.get(c)
    if not r:
        print(f"  {c:22} not in the report (rerun whatif after the layer exists)")
        continue
    rec = r.get("recovery_s")
    print(f"  {c:22} {r['status']:8} worst={r['worst_status']:9} recovery={r['recovery']}"
          f"{f' ~{rec:g} s' if rec is not None else ''}  {r['summary']}")
    for f in r.get("flows", []):
        frs = f.get("recovery_s")
        print(f"      {f['flow']:16} {f['status']:9} impact {f['impact_pct']:g}%"
              f"{f'  recovers ~{frs:g} s' if frs is not None else ''}")
PY
}

# ==================== on fw-a: unbound and the Route 53 block ====================

UNBOUND_BODY=$(cat <<'EOF'
command -v unbound >/dev/null && command -v unbound-control >/dev/null || {
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unbound >/dev/null; }
# The package's own instance (and its resolv.conf hook) must not touch the firewall's DNS
systemctl disable --now unbound unbound-resolvconf >/dev/null 2>&1 || true
ip6=no; ip -6 route show default 2>/dev/null | grep -q . && ip6=yes
cat > /etc/unbound/cb-test1.conf <<UBEOF
# CloudBridge Test 1: plain recursive resolver for timing authoritative servers. Iterator only
# (no DNSSEC validation), tiny TTL cap; the test also flushes the caches before every query.
server:
  interface: 127.0.0.1
  port: $PORT
  access-control: 127.0.0.0/8 allow
  do-ip6: $ip6
  module-config: "iterator"
  cache-max-ttl: 1
  cache-max-negative-ttl: 1
  prefetch: no
  qname-minimisation: no
  chroot: ""
  directory: "/etc/unbound"
  pidfile: ""
  use-syslog: yes
  verbosity: 1
remote-control:
  control-enable: yes
  control-interface: 127.0.0.1
  control-port: 8954
  control-use-cert: no
UBEOF
if ! systemctl is-active -q cb-unbound; then
  systemctl reset-failed cb-unbound >/dev/null 2>&1 || true
  systemd-run --quiet --unit cb-unbound /usr/sbin/unbound -d -c /etc/unbound/cb-test1.conf
  sleep 2
fi
echo "unbound: $(systemctl is-active cb-unbound) ($(unbound -V | head -1)), do-ip6 $ip6"
unbound-control -c /etc/unbound/cb-test1.conf status | grep -E "^version|is running" || echo "unbound-control FAILED"
echo "test query: $(dig -p $PORT @127.0.0.1 +time=10 +tries=1 +short $APP | tr '\n' ' ')"
EOF
)

BLOCK_BODY=$(cat <<'EOF'
nft delete table inet cbt1 2>/dev/null || true
s4=""; [ -n "$V4" ] && s4="set r53v4 { type ipv4_addr; elements = { $V4 } }"
s6=""; [ -n "$V6" ] && s6="set r53v6 { type ipv6_addr; elements = { $V6 } }"
r4=""; [ -n "$V4" ] && r4="ip daddr @r53v4 counter drop"
r6=""; [ -n "$V6" ] && r6="ip6 daddr @r53v6 counter drop"
nft -f - <<NFTEOF
table inet cbt1 {
  $s4
  $s6
  chain out {
    type filter hook output priority 0; policy accept;
    $r4
    $r6
  }
}
NFTEOF
# Safety net: the table goes away on its own even if the laptop never sends the unblock
systemctl stop cb-t1-unblock.timer >/dev/null 2>&1 || true
systemctl reset-failed cb-t1-unblock.service cb-t1-unblock.timer >/dev/null 2>&1 || true
systemd-run --quiet --unit cb-t1-unblock --on-active=${SAFETY}m /usr/sbin/nft delete table inet cbt1
echo "blocked on fw-a OUTPUT: $(echo "$V4" | tr ',' '\n' | grep -c .) IPv4, $(echo "$V6" | tr ',' '\n' | grep -c .) IPv6 (auto-unblock in ${SAFETY} min)"
EOF
)

UNBLOCK_BODY=$(cat <<'EOF'
nft list table inet cbt1 2>/dev/null | grep -E "counter" | sed 's/^[[:space:]]*/  /' || true
nft delete table inet cbt1 2>/dev/null && echo "block lifted" || echo "no block in place"
systemctl stop cb-t1-unblock.timer >/dev/null 2>&1 || true
EOF
)

# One timed query per line: "q <phase> <i> <wall_ms> <status> <provider> <r53_tried> <r53_rto_max> <az_tried>"
# provider: azure-dns when the answer starts with the CNAME to Traffic Manager (only Azure DNS
# serves that), route53 when it starts with an A record (the failover records), none otherwise.
# r53_tried / az_tried: that provider's servers in unbound's infra cache after the query, which
# is flushed before it, so = the servers unbound sent this query to.
MEASURE_BODY=$(cat <<'EOF'
UC="unbound-control -c /etc/unbound/cb-test1.conf"
for i in $(seq 1 "$N"); do
  $UC flush_zone . >/dev/null; $UC flush_negative >/dev/null 2>&1 || true
  [ "$KEEP_INFRA" = 1 ] || $UC flush_infra all >/dev/null
  t0=$(date +%s%3N)
  out=$(dig -p $PORT @127.0.0.1 +tries=1 +time=15 $APP A 2>&1)
  t1=$(date +%s%3N)
  ans=$(echo "$out" | awk '
    /status:/ { for (k = 1; k <= NF; k++) if ($k == "status:") { st = $(k + 1); sub(/,/, "", st) } }
    /^;; ANSWER SECTION:/ { a = 1; next }
    a && /^$/ { a = 0 }
    a && first == "" { first = $4 }
    a && $4 == "CNAME" && $5 ~ /trafficmanager\.net/ { tm = 1 }
    END { print (st == "" ? "TIMEOUT" : st), (tm ? "azure-dns" : (first == "A" ? "route53" : "none")) }')
  inf=$($UC dump_infra 2>/dev/null | awk -v r53="$R53" -v azns="$AZNS" '
    BEGIN { n = split(r53, a, " "); for (k = 1; k <= n; k++) R[a[k]] = 1
            n = split(azns, b, " "); for (k = 1; k <= n; k++) Z[b[k]] = 1 }
    $1 in R { rt++; for (j = 2; j < NF; j++) if ($j == "rto" && $(j + 1) + 0 > rto) rto = $(j + 1) + 0 }
    $1 in Z { zt++ }
    END { print rt + 0, rto + 0, zt + 0 }')
  echo "q $PHASE $i $((t1 - t0)) $ans $inf"
  sleep 0.5
done
EOF
)

# Poll every 2 s for $DUR s: fresh-cache resolution through unbound, then /health on the
# address it returned. The CSV comes back gzip+base64 (SSM keeps 24,000 chars of output).
POLL_BODY=$(cat <<'EOF'
UC="unbound-control -c /etc/unbound/cb-test1.conf"
f=/var/tmp/cb-t1-poll-$(date +%s).csv
echo "epoch_ms,dns_ms,status,provider,final_ip,http_code,cloud,r53_tried" > "$f"
end=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$end" ]; do
  t0=$(date +%s%3N)
  $UC flush_zone . >/dev/null; $UC flush_infra all >/dev/null; $UC flush_negative >/dev/null 2>&1 || true
  out=$(dig -p $PORT @127.0.0.1 +tries=1 +time=10 $APP A 2>&1)
  t1=$(date +%s%3N)
  read -r st prov ip <<<"$(echo "$out" | awk '
    /status:/ { for (k = 1; k <= NF; k++) if ($k == "status:") { st = $(k + 1); sub(/,/, "", st) } }
    /^;; ANSWER SECTION:/ { ans = 1; next }
    ans && /^$/ { ans = 0 }
    ans && first == "" { first = $4 }
    ans && $4 == "CNAME" && $5 ~ /trafficmanager\.net/ { tm = 1 }
    ans && $4 == "A" { ip = $5 }
    END { print (st == "" ? "TIMEOUT" : st), (tm ? "azure-dns" : (first == "A" ? "route53" : "none")), (ip == "" ? "-" : ip) }')"
  rt=$($UC dump_infra 2>/dev/null | awk -v r53="$R53" 'BEGIN { n = split(r53, a, " "); for (k = 1; k <= n; k++) R[a[k]] = 1 } $1 in R { c++ } END { print c + 0 }')
  code=000; cloud=none
  if [ "$ip" != "-" ]; then
    body=$(curl -s --max-time 3 --resolve "$APP:80:$ip" -w '\n%{http_code}' "http://$APP/health" 2>/dev/null || true)
    code=$(tail -n1 <<<"$body"); code=${code:-000}
    cloud=$(head -n1 <<<"$body" | sed -n 's/.*"cloud":"\([a-z]*\)".*/\1/p'); cloud=${cloud:-none}
  fi
  echo "$t0,$((t1 - t0)),$st,$prov,$ip,$code,$cloud,$rt" >> "$f"
  left=$(( 2000 - ($(date +%s%3N) - t0) )); [ "$left" -gt 0 ] && sleep "$(awk -v l=$left 'BEGIN { print l / 1000 }')"
done
echo "raw on fw-a: $f ($(($(wc -l < "$f") - 1)) polls)"
echo "B64:$(gzip -9c "$f" | base64 -w0)"
EOF
)

FWA=""; hcpid=""
fwa() { [ -n "$FWA" ] || FWA=$(iid cloudbridge-fw-a); echo "$FWA"; }

R53_V4=""; R53_V6=""; AZ_V4=""
load_ns_ips() {  # every Route 53 name server of the zone (hosted zone + whatever the TLD delegates to)
  local names n tld
  tld=$(tld_servers | sed -n 1p)
  names=$( { r53_ns; tld_delegation "$tld" | grep awsdns || true; } | sort -u)
  [ -n "$names" ] || { echo "no Route 53 name servers found" >&2; exit 1; }
  R53_V4=$(for n in $names; do a_of "$n"; done | sort -u | tr '\n' ' ' | sed 's/ $//')
  R53_V6=$(for n in $names; do aaaa_of "$n"; done | sort -u | tr '\n' ' ' | sed 's/ $//')
  AZ_V4=$(for n in $(az_ns); do a_of "$n"; done | sort -u | tr '\n' ' ' | sed 's/ $//')
  if [ "${BLOCK_ELB:-0}" = 1 ]; then  # the ALB's own zone is on Route 53 too
    local alb zone
    alb=$(alb_dns)
    zone=$(dig +noall +authority SOA "$alb" @1.1.1.1 | awk '$4 == "SOA" { print $1; exit }')
    [ -n "$zone" ] || zone=$(dig +noall +answer SOA "${alb#*.}" @1.1.1.1 | awk '$4 == "SOA" { print $1; exit }')
    echo "BLOCK_ELB=1: also blocking the name servers of $zone"
    R53_V4="$R53_V4 $(for n in $(dig +short NS "$zone" @1.1.1.1); do a_of "$n"; done | sort -u | tr '\n' ' ')"
    R53_V6="$R53_V6 $(for n in $(dig +short NS "$zone" @1.1.1.1); do aaaa_of "$n"; done | sort -u | tr '\n' ' ')"
    R53_V4=$(tr ' ' '\n' <<<"$R53_V4" | grep . | sort -u | tr '\n' ' ' | sed 's/ $//')
    R53_V6=$(tr ' ' '\n' <<<"$R53_V6" | grep . | sort -u | tr '\n' ' ' | sed 's/ $//')
  fi
  echo "Route 53 NS names : $(tr '\n' ' ' <<<"$names")"
  echo "Route 53 NS IPv4  : $R53_V4"
  echo "Route 53 NS IPv6  : ${R53_V6:-none}"
  echo "Azure DNS NS IPv4 : $AZ_V4"
}
block_r53() {
  ssm "$(fwa)" "V4=\"$(sed 's/ /, /g' <<<"$R53_V4")\"; V6=\"$(sed 's/ /, /g' <<<"$R53_V6")\"; SAFETY=$SAFETY_MIN" "$BLOCK_BODY" 120
}
unblock_r53() { ssm "$(fwa)" "" "$UNBLOCK_BODY" 120; }
ensure_unbound() {
  echo "== unbound on fw-a (127.0.0.1:$UB_PORT)"
  ssm "$(fwa)" "PORT=$UB_PORT; APP=$APP" "$UNBOUND_BODY" 600
}
measure() {  # $1 phase, $2 keep infra (0/1), [$3 count] -> q lines
  ssm "$(fwa)" "N=${3:-$N}; PHASE=$1; KEEP_INFRA=$2; PORT=$UB_PORT; APP=$APP; R53=\"$R53_V4 $R53_V6\"; AZNS=\"$AZ_V4\"" "$MEASURE_BODY" 900
}

summarize_q() {  # stdin: q lines
  python3 -c '
import sys, statistics as S
ph = {}
for l in sys.stdin:
    p = l.split()
    if len(p) == 9 and p[0] == "q":
        ph.setdefault(p[1], []).append(p)
base = None
for name, rows in ph.items():
    ms = sorted(int(r[3]) for r in rows)
    ok = [r for r in rows if r[4] == "NOERROR" and r[5] != "none"]
    prov = {}
    for r in rows: prov[r[5]] = prov.get(r[5], 0) + 1
    med = S.median(ms); p90 = ms[min(len(ms) - 1, int(0.9 * len(ms)))]
    tried = sum(int(r[6]) for r in rows) / len(rows)
    line = (f"{name:14} ok {len(ok)}/{len(rows)}  median {med:.0f} ms  p90 {p90} ms  max {ms[-1]} ms  "
            f"answered by: " + " ".join(f"{k}={v}" for k, v in sorted(prov.items())) +
            f"  Route 53 servers tried per query: {tried:.1f}")
    if base is None: base = med
    else: line += f"  (+{med - base:.0f} ms vs normal)"
    print(line)
'
}

# ==================== subcommands ====================

cmd_check() {
  local out=$OUT-check.txt ns tld r fwip alb tmf tmns
  {
    set +e   # read-only report: one failed lookup must not end it
    echo "== $(date -u +%FT%TZ) check of $DOMAIN"
    echo "-- registrar name servers (Route 53 Domains)"; registrar_ns | sed 's/^/  /'
    echo "-- Route 53 hosted zone name servers"; r53_ns | sed 's/^/  /'
    echo "-- Azure DNS zone name servers"; az_ns | sed 's/^/  /' || echo "  (no Azure zone)"
    echo
    echo "== Delegation from the .click TLD servers (dig +norecurse NS $DOMAIN @<tld>)"
    for tld in $(tld_servers); do
      printf "  %-28s %s\n" "$tld" "$(tld_delegation "$tld" | tr '\n' ' ')"
    done
    echo "  full referral from $(tld_servers | sed -n 1p):"
    dig +norecurse +noall +authority +additional NS "$DOMAIN" @"$(tld_servers | sed -n 1p)" | sed 's/^/    /'
    echo
    echo "== Apex NS that each provider serves (the child-side NS set)"
    for ns in $(r53_ns) $(az_ns); do
      printf "  %-32s %s\n" "$ns" "$(dig +norecurse +short +time=2 +tries=1 NS "$DOMAIN" @"$ns" | strip_dot | sort | tr '\n' ' ')"
    done
    echo
    echo "== $APP at every authoritative server (dig +norecurse @ns)"
    for ns in $(r53_ns) $(az_ns); do
      echo "  -- @$ns"
      dig +norecurse +time=2 +tries=1 +noall +answer +comments "$APP" A @"$ns" |
        grep -E "status:|IN" | sed -e 's/^;; ->>HEADER<<- //' -e 's/^/     /'
    done
    tmf=$(tm_fqdn)
    if [ -n "$tmf" ]; then
      tmns=$(dig +short NS trafficmanager.net @1.1.1.1 | sed -n 1p)
      echo
      echo "== Traffic Manager: $tmf @$tmns"
      dig +norecurse +noall +answer "$tmf" @"$tmns" | sed 's/^/  /'
      az network traffic-manager profile show -g "$RG" -n "$(tm_profile)" \
        --query '{status:profileStatus, monitor:monitorStatus, ttl:dnsConfig.ttl, path:monitorConfig.path, interval:monitorConfig.intervalInSeconds, failures:monitorConfig.toleratedNumberOfFailures}' -o tsv | sed 's/^/  profile: /'
      az network traffic-manager profile show -g "$RG" -n "$(tm_profile)" \
        --query 'endpoints[].[priority, name, target, endpointMonitorStatus]' -o tsv | sed 's/^/  endpoint: /'
    fi
    echo
    echo "== $APP through public resolvers"
    for r in $PUBLIC_RESOLVERS; do
      printf "  %-16s %s\n" "@$r" "$(dig +time=3 +tries=1 +noall +answer "$APP" A @"$r" | awk '{ printf "%s %s %s %s | ", $1, $2, $4, $5 }')"
    done
    echo
    fwip=$(fw_public_ip)
    echo "== Health checks and HTTP"
    echo "  Route 53: $(r53_hc_summary "$fwip")"
    echo "  Traffic Manager: $(tm_endpoints)"
    alb=$(alb_dns 2>/dev/null || true)
    [ -n "$alb" ] && echo "  ALB  /health: $(curl -s --max-time 3 "http://$alb/health" || echo FAILED)"
    echo "  Azure fw $fwip /health: $(curl -s --max-time 3 "http://$fwip/health" || echo FAILED)"
  } | tee "$out"
  echo "saved: $out"
}

cmd_delegation() {
  local want tld got bad=0
  want=$(registrar_ns | tr '\n' ' ')
  echo "registrar: $want"
  for tld in $(tld_servers); do
    got=$(tld_delegation "$tld" | tr '\n' ' ')
    if [ "$got" = "$want" ]; then echo "  $tld OK"; else echo "  $tld STALE: $got"; bad=1; fi
  done
  if [ "$bad" = 0 ]; then echo "DELEGATION OK"; else echo "DELEGATION NOT YET (TLD NS TTL is 900 s)"; return 1; fi
}

cmd_provider_loss() {
  local out=$OUT-provider-loss
  load_ns_ips > "$out-ips.txt"; cat "$out-ips.txt"
  [ -n "$R53_V4" ] || { echo "no Route 53 IPs resolved" >&2; exit 1; }
  ensure_unbound
  save_prediction "$out-mindbridge.json" dns-route53 dns-azure registrar
  trap 'echo "EXIT: lifting the block on fw-a"; unblock_r53 || true' EXIT
  unblock_r53 >/dev/null

  echo; echo "== Step 1: everything normal, $N queries, cache flushed before each"
  measure normal 0 | tee "$out.raw"
  echo; echo "== Blocking every Route 53 name server IP on fw-a OUTPUT"
  block_r53
  echo; echo "== Step 2: Route 53 unreachable, cold cache (every query starts knowing nothing)"
  measure blocked-cold 0 | tee -a "$out.raw"
  echo; echo "== Step 3: Route 53 unreachable, unbound keeps its server-timeout (infra) cache"
  measure blocked-warm 1 | tee -a "$out.raw"
  echo; echo "== nft drop counters, then unblock"
  unblock_r53 | tee "$out-nft.txt"
  trap - EXIT

  {
    echo "test1 provider-loss $(date -u +%FT%TZ)  resolver: unbound on fw-a, iterator only, caches flushed per query"
    echo "columns: q phase i wall_ms status provider r53_servers_tried r53_rto_max_ms azure_servers_tried"
    echo
    summarize_q < "$out.raw"
    echo
    echo "nft (Route 53 IPs dropped on OUTPUT):"; cat "$out-nft.txt"
    echo
    python3 - "$out-mindbridge.json" <<'PY'
import json, sys
try:
    r = json.load(open(sys.argv[1]))["components"].get("dns-route53")
except Exception:
    r = None
if r:
    print(f"MindBridge AI predicted for dns-route53: {r['worst_status']}, recovery {r['recovery']} ~{r.get('recovery_s')} s "
          "per lookup (a resolver timeout, then the other provider). Compare with the +ms above.")
PY
  } | tee "$out.txt"
  echo "saved: $out.txt $out.raw $out-ips.txt $out-nft.txt $out-mindbridge.json"
}

cmd_failover() {
  local out=$OUT-failover-no-r53 fwip reps dur cid BREAK RESTORE raw   # hcpid: global (EXIT trap)
  fwip=$(fw_public_ip)
  reps=$($K get deploy frontend -o jsonpath='{.spec.replicas}')
  [ "${reps:-0}" -gt 0 ] || reps=3
  load_ns_ips > "$out-ips.txt"; cat "$out-ips.txt"
  ensure_unbound
  echo; echo "== Blocking Route 53 on fw-a for the whole run"
  block_r53
  trap 'echo "EXIT: frontend back to '"$reps"', lifting the block"; $K scale deploy/frontend --replicas='"$reps"' >/dev/null || true; [ -n "$hcpid" ] && kill "$hcpid" 2>/dev/null; unblock_r53 || true' EXIT

  echo; echo "== Before the break (must be azure-dns answers pointing at AWS):"
  measure precheck 0 3 | sed 's/^/  /'
  save_prediction "$out-mindbridge.json" dns-route53 dns-failover-tm dns-failover-r53 aws-alb

  dur=$(( BASELINE + OUTAGE + RECOVERY + 30 ))
  cid=$(ssm_send "$(fwa)" "DUR=$dur; PORT=$UB_PORT; APP=$APP; R53=\"$R53_V4 $R53_V6\"" "$POLL_BODY" "$(( dur + 120 ))")
  hc_watch "$out-healthchecks.csv" "$fwip" &
  hcpid=$!
  echo "fw-a polls every 2 s for ${dur}s; baseline ${BASELINE}s..."
  sleep "$BASELINE"

  BREAK=$(now_ms)
  $K scale deploy/frontend --replicas=0 >/dev/null
  echo "$(iso_ms "$BREAK") frontend scaled 3 -> 0 (ALB /health fails); outage ${OUTAGE}s..."
  sleep "$OUTAGE"
  RESTORE=$(now_ms)
  $K scale deploy/frontend --replicas="$reps" >/dev/null
  echo "$(iso_ms "$RESTORE") frontend back to $reps (Route 53 still blocked); recovery ${RECOVERY}s..."
  sleep "$RECOVERY"

  echo "waiting for the fw-a poll to finish..."
  raw=$(ssm_wait "$(fwa)" "$cid" "$(( dur + 300 ))")
  kill "$hcpid" 2>/dev/null || true
  grep '^raw on' <<<"$raw" || true
  sed -n 's/^B64://p' <<<"$raw" | b64_decode > "$out.csv"
  echo; echo "== lifting the block"
  unblock_r53 | tee "$out-nft.txt"
  trap - EXIT
  echo "break=$BREAK restore=$RESTORE fw_public_ip=$fwip replicas=$reps block_elb=${BLOCK_ELB:-0}" > "$out.meta"

  python3 - "$out.csv" "$BREAK" "$RESTORE" "$fwip" "$out-healthchecks.csv" <<'PY' | tee "$out.txt"
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
brk, rst, fwip = int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
for r in rows: r["t"] = int(r["epoch_ms"])
s = lambda ms: f"{ms / 1000:.1f} s"
print("test1 failover-without-route53: fw-a resolves through unbound with every Route 53 name server dropped")
print(f"polls: {len(rows)}  answered by: " + ", ".join(f"{p}={sum(r['provider'] == p for r in rows)}"
      for p in sorted({r['provider'] for r in rows})))
print("Route 53 servers tried per poll (all timed out): mean "
      f"{sum(int(r['r53_tried']) for r in rows) / max(len(rows), 1):.1f}")
ms = sorted(int(r["dns_ms"]) for r in rows)
if ms: print(f"resolution time: median {ms[len(ms) // 2]} ms, max {ms[-1]} ms")
after = [r for r in rows if brk <= r["t"] < rst]
az_dns = next((r for r in after if r["final_ip"] == fwip), None)
az_http = next((r for r in after if r["final_ip"] == fwip and r["http_code"] == "200" and r["cloud"] == "azure"), None)
first_fail = next((r for r in after if r["http_code"] != "200"), None)
failed = sum(r["http_code"] != "200" for r in after)
if first_fail: print(f"first failed /health      : break + {s(first_fail['t'] - brk)}")
print(f"answer points at Azure    : {('break + ' + s(az_dns['t'] - brk)) if az_dns else 'never'}")
print(f'HTTP "cloud":"azure"      : {("break + " + s(az_http["t"] - brk)) if az_http else "never"}  <- failover time, Route 53 unreachable')
print(f"failed polls in outage    : {failed} of {len(after)}")
back = [r for r in rows if r["t"] >= rst]
aws_dns = next((r for r in back if r["final_ip"] not in (fwip, "-")), None)
aws_http = next((r for r in back if r["http_code"] == "200" and r["cloud"] == "aws"), None)
print(f"answer points at AWS again: {('restore + ' + s(aws_dns['t'] - rst)) if aws_dns else 'not yet'}")
print(f'HTTP "cloud":"aws" again  : {("restore + " + s(aws_http["t"] - rst)) if aws_http else "not yet"}  <- failback time')
print(f"failed polls in failback  : {sum(r['http_code'] != '200' for r in back)} of {len(back)}")
try:
    hc = list(csv.DictReader(open(sys.argv[5])))
    prev = None
    print("health-check view (laptop, ~10 s samples):")
    for h in hc:
        cur = (h["traffic_manager"], h["route53"])
        if cur != prev:
            t = int(h["epoch_ms"])
            rel = f"break + {s(t - brk)}" if t < rst else f"restore + {s(t - rst)}"
            print(f"  {rel:>18}  {h['traffic_manager']} {h['route53']}")
            prev = cur
except FileNotFoundError:
    pass
PY
  echo "saved: $out.txt $out.csv $out-healthchecks.csv $out.meta $out-mindbridge.json"
}

cmd_cleanup() {
  unblock_r53
  ssm "$(fwa)" "" 'systemctl stop cb-unbound 2>/dev/null; systemctl reset-failed cb-unbound 2>/dev/null; echo "unbound: $(systemctl is-active cb-unbound)"' 60
}

case "${1:-}" in
  check)                    cmd_check ;;
  delegation)               cmd_delegation ;;
  provider-loss)            cmd_provider_loss ;;
  failover-without-route53) cmd_failover ;;
  cleanup)                  cmd_cleanup ;;
  *) echo "usage: $0 check|delegation|provider-loss|failover-without-route53|cleanup" >&2; exit 1 ;;
esac
