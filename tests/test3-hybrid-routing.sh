#!/usr/bin/env bash
# Test 3: hybrid routing failover over the active-active VPN (4 tunnels, eBGP, TGW ECMP).
# Session 1 has no clusters: traffic runs between the Azure hub firewall (10.20.241.4) and
# the two AWS test hosts (10.10.0.10 in 2a, 10.10.0.74 in 2b).
#
#   check          read-only health check: cloud-init on the 3 firewalls, ping + HTTP from the
#                  Azure firewall to both test hosts, DNS across clouds
#   tunnels        read-only snapshot: AWS tunnel state, Azure connections, BGP peers, learned
#                  routes, Azure byte counters, AWS CloudWatch per-tunnel bytes (last 30 min)
#   paths          per-tunnel byte counters before/after an iperf3 burst: is ECMP using all 4?
#   bgp-break      wrong peer ASN on the busiest tunnel's LNG (IPsec stays up) with a 5/s ping
#                  running; times the reroute, then restores the ASN
#   instance-down [instance0|instance1]
#                  resets one Azure gateway instance (2 tunnels) with the same ping; times the
#                  reroute and the recovery
#   mtu            DF-ping path MTU each way + the TCP MSS seen on the far side (tcpdump)
#
# Results go to docs/runs/test3-*. bgp-break and instance-down change Azure state and put it
# back; nothing here runs terraform.
#
# Usage: ./test3-hybrid-routing.sh check|tunnels|paths|bgp-break|instance-down|mtu
set -euo pipefail
cd "$(dirname "$0")"

RG=cloudbridge-rg
GW=cloudbridge-vpngw
AZFW=cloudbridge-fw
AZFW_IP=10.20.241.4
HOST_A=10.10.0.10
HOST_B=10.10.0.74
FWA_IP=10.10.240.40
TUNNELS="c0-t1 c0-t2 c1-t1 c1-t2"
AWS_ASN=64512
BAD_ASN=65000   # any ASN AWS isn't using: Azure rejects the TGW's BGP OPEN, IPsec stays up
BROKEN=180      # seconds to leave BGP broken
RECOVERY=240    # seconds to watch after restoring
RESET_WATCH=720 # seconds to watch after an instance reset
OUT=../docs/runs/test3
AWS="aws --region us-east-2"
mkdir -p ../docs/runs

# ==================== helpers ====================

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
iso_ago() { python3 -c "import datetime as d,sys; print((d.datetime.now(d.timezone.utc)-d.timedelta(minutes=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }

# Wrap a bash script so it runs the same under sh or bash. $1 = variable lines, $2 = body.
wrap() { printf "bash -s <<'CBEOF'\n%s\n%s\nCBEOF\n" "$1" "$2"; }

# Run a script on the Azure firewall as root (az vm run-command; there is no SSH).
# Run Command returns only the last 4 KB of output, so remote scripts print summaries.
azfw() {  # $1 = vars, $2 = body
  local msg
  msg=$(az vm run-command invoke -g "$RG" -n "$AZFW" --command-id RunShellScript \
    --scripts "$(wrap "$1" "$2")" --query 'value[0].message' -o tsv)
  awk '/^\[stdout\]/{f=1;next} /^\[stderr\]/{f=0} f' <<<"$msg"
  awk '/^\[stderr\]/{f=1;next} f' <<<"$msg" | grep -v '^$' | sed 's/^/  [azfw stderr] /' >&2 || true
}

# AWS instances by Name tag, reached with SSM Run Command (no SSH)
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
ssm_wait() {  # $1 instance id, $2 command id, [$3 max wait s] -> stdout
  local st=Pending end=$(( $(date +%s) + ${3:-900} ))
  while [ "$(date +%s)" -lt "$end" ]; do
    st=$($AWS ssm get-command-invocation --instance-id "$1" --command-id "$2" --query Status --output text 2>/dev/null || echo Pending)
    case "$st" in Pending|InProgress|Delayed) sleep 3 ;; *) break ;; esac
  done
  $AWS ssm get-command-invocation --instance-id "$1" --command-id "$2" --query StandardOutputContent --output text 2>/dev/null || true
  [ "$st" = Success ] || echo "  (ssm on $1: $st)" >&2
}
ssm() {  # send + wait
  local cid
  cid=$(ssm_send "$1" "$2" "$3" "${4:-600}")
  ssm_wait "$1" "$cid" "$(( ${4:-600} + 120 ))"
}

# Tunnel key (c0-t1 ...) <-> AWS outside IP, read from the Azure local network gateways
MAP=""
load_map() {
  local t ip
  MAP=""
  for t in $TUNNELS; do
    ip=$(az network local-gateway show -g "$RG" -n "cloudbridge-lng-aws-$t" --query gatewayIpAddress -o tsv)
    MAP="$MAP$t $ip"$'\n'
  done
}
key_for_ip() { awk -v ip="$1" '$2 == ip { print $1 }' <<<"$MAP"; }
ip_for_key() { awk -v k="$1" '$1 == k { print $2 }' <<<"$MAP"; }

# AWS side. Only these fields are queried: describe-vpn-connections also returns the tunnel
# config (with pre-shared keys), which must never be printed or saved.
aws_state() {  # "c0-t1=UP/2 c0-t2=UP/2 ..." (status / accepted BGP routes)
  local ip st n
  $AWS ec2 describe-vpn-connections \
    --filters "Name=tag:Name,Values=cloudbridge-vpn-azure-c0,cloudbridge-vpn-azure-c1" "Name=state,Values=available" \
    --query 'VpnConnections[].VgwTelemetry[].[OutsideIpAddress,Status,AcceptedRouteCount]' --output text 2>/dev/null |
    while read -r ip st n; do echo "$(key_for_ip "$ip")=$st/$n"; done | sort | tr '\n' ' '
}
az_bytes() {  # $1 tunnel key -> "ingress egress" (ingress = received from AWS)
  az network vpn-connection show -g "$RG" -n "cloudbridge-conn-aws-$1" \
    --query "[ingressBytesTransferred, egressBytesTransferred]" -o tsv 2>/dev/null | tr '\t\n' '  ' | sed 's/ *$//'
  # -o tsv prints a list one value per line, so newlines are joined too
}
az_conns() {  # "c0-t1=Connected ..."
  az network vpn-connection list -g "$RG" --query "[].[name,connectionStatus]" -o tsv 2>/dev/null |
    sed 's/^cloudbridge-conn-aws-//' | sort | awk '{printf "%s=%s ", $1, $2}'
}
peers() {  # "169.254.21.1=Connected ..."
  az network vnet-gateway list-bgp-peer-status -g "$RG" -n "$GW" \
    --query "value[].[neighbor,state]" -o tsv 2>/dev/null | sort -u | awk '{printf "%s=%s ", $1, $2}'
}
snapshot() {  # one CSV line
  echo "$(now_ms),$1,$(peers),$(az_conns),$(aws_state)"
}
watch_state() {  # $1 phase, $2 seconds, $3 csv
  local end=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$end" ]; do snapshot "$1" | tee -a "$3"; sleep 5; done
}
counters() {  # all 4 Azure connections: "key ingress egress" lines
  local t
  for t in $TUNNELS; do echo "$t $(az_bytes "$t")"; done
}

# 5/s ping from the Azure firewall to host-a for $1 seconds. The raw log stays on the VM
# (/var/tmp/cb-ping-*.txt); only the gaps come back (Run Command keeps the last 4 KB).
PING_BODY=$(cat <<'EOF'
f=/var/tmp/cb-ping-$(date +%s).txt
ping -D -O -i 0.2 -w "$DUR" "$DST" > "$f" 2>&1 || true
echo "raw log on the VM: $f"
awk '/bytes from/ { gsub(/\[|\]/, "", $1); t = $1 + 0; if (!first) first = t
                    if (prev && t - prev > 0.5) { g++; if (g <= 40) printf "gap %.3f %.3f %.3f\n", prev, t, t - prev }
                    prev = t; r++ }
     /no answer yet/ { m++ }
     END { printf "summary received=%d no_answer=%d gaps=%d first=%.3f last=%.3f\n", r, m, g, first, prev }' "$f"
EOF
)

# Gaps in the remote ping vs the break/restore times
analyze_ping() {  # $1 ping summary file, $2 break ms, $3 restore ms (or 0), $4 label
  python3 - "$@" <<'PY'
import sys
f, brk, rst, label = sys.argv[1], int(sys.argv[2]) / 1000, int(sys.argv[3]) / 1000, sys.argv[4]
gaps, summary = [], ""
for line in open(f):
    p = line.split()
    if p and p[0] == "gap":
        gaps.append((float(p[1]), float(p[2]), float(p[3])))
    elif p and p[0] == "summary":
        summary = line.strip()
print(f"== {label}")
print(summary)
if not gaps:
    print("No gap over 0.5 s: the ping flow never lost more than 2 replies.")
    print("Either the reroute was sub-second or this flow was not on the broken path.")
for s, e, d in gaps:
    rel = f"break+{s - brk:.1f}s"
    if rst and s >= rst - 1:
        rel = f"restore+{s - rst:.1f}s"
    print(f"gap of {d:6.2f}s starting at {rel} (~{int(round(d / 0.2)) - 1} replies lost)")
during = [d for s, e, d in gaps if s >= brk - 1 and (not rst or s < rst - 1)]
after = [d for s, e, d in gaps if rst and s >= rst - 1]
print(f"outage after break  : {sum(during):.2f}s in {len(during)} gap(s)")
if rst:
    print(f"outage after restore: {sum(after):.2f}s in {len(after)} gap(s)")
PY
}

ensure_iperf_hosts() {
  local h
  for h in cloudbridge-app-host-a cloudbridge-app-host-b; do
    ssm "$(iid $h)" "" '
command -v iperf3 >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iperf3 >/dev/null; }
pgrep -x iperf3 >/dev/null || iperf3 -s -D
command -v iperf3 >/dev/null && echo "$(hostname): iperf3 server up" || echo "$(hostname): NO iperf3"' 300
  done
}

# ==================== subcommands ====================

cmd_check() {
  local f
  echo "== AWS firewalls: cloud-init, nftables, dnsmasq"
  for f in cloudbridge-fw-a cloudbridge-fw-b; do
    echo "-- $f"
    ssm "$(iid $f)" "" '
cloud-init status --wait >/dev/null 2>&1; cloud-init status
echo "nftables: $(systemctl is-active nftables)  dnsmasq: $(systemctl is-active dnsmasq)  ip_forward: $(sysctl -n net.ipv4.ip_forward)"
nft list tables' 300
  done

  echo; echo "== Azure firewall: cloud-init, ping + HTTP to both test hosts, DNS to AWS"
  azfw "A=$HOST_A; B=$HOST_B; FWA=$FWA_IP" '
cloud-init status --wait >/dev/null 2>&1; cloud-init status
echo "nftables: $(systemctl is-active nftables)  dnsmasq: $(systemctl is-active dnsmasq)  ip_forward: $(sysctl -n net.ipv4.ip_forward)"
for h in $A $B; do
  echo "-- $h"; ping -c 3 -W 2 $h | tail -2
  echo "HTTP: $(curl -s --max-time 3 http://$h/ || echo FAILED)"
done
echo "-- dig @10.20.241.4 fw-a.cloudbridge.internal (Azure -> AWS forwarder -> Route 53 private zone)"
dig +time=3 +tries=1 @10.20.241.4 fw-a.cloudbridge.internal | grep -E "status:|^fw-a" || echo "no answer"'

  echo; echo "== DNS AWS -> Azure: from fw-a, dig @$FWA_IP fw.az.cloudbridge.internal"
  ssm "$(iid cloudbridge-fw-a)" "" '
dig +time=3 +tries=1 @10.10.240.40 fw.az.cloudbridge.internal | grep -E "status:|^fw\.az" || echo "no answer"
echo "-- ping Azure firewall"; ping -c 3 -W 2 10.20.241.4 | tail -2' 120
}

cmd_tunnels() {
  load_map
  local t ip m
  echo "== AWS VPN tunnels (status / accepted BGP routes)"
  $AWS ec2 describe-vpn-connections \
    --filters "Name=tag:Name,Values=cloudbridge-vpn-azure-c0,cloudbridge-vpn-azure-c1" "Name=state,Values=available" \
    --query 'VpnConnections[].[Tags[?Key==`Name`]|[0].Value, VgwTelemetry[].[OutsideIpAddress,Status,AcceptedRouteCount,StatusMessage]]' \
    --output text
  echo; echo "== Azure connections"
  az network vpn-connection list -g "$RG" --query "[].{name:name,status:connectionStatus}" -o table
  echo; echo "== Azure BGP peers"
  az network vnet-gateway list-bgp-peer-status -g "$RG" -n "$GW" -o table
  echo; echo "== Azure learned routes from AWS (EBgp)"
  az network vnet-gateway list-learned-routes -g "$RG" -n "$GW" \
    --query "value[?origin=='EBgp'].{network:network,nextHop:nextHop,sourcePeer:sourcePeer,asPath:asPath}" -o table
  echo; echo "== Azure byte counters (ingress = from AWS, egress = to AWS)"
  for t in $TUNNELS; do echo "$t $(az_bytes "$t")"; done
  echo; echo "== AWS CloudWatch per-tunnel bytes, last 30 min (published every 5 min, lags ~5-10 min)"
  for t in $TUNNELS; do
    ip=$(ip_for_key "$t")
    for m in TunnelDataIn TunnelDataOut; do
      printf "%s %-15s %-13s " "$t" "$ip" "$m"
      $AWS cloudwatch get-metric-statistics --namespace AWS/VPN --metric-name "$m" \
        --dimensions "Name=TunnelIpAddress,Value=$ip" --start-time "$(iso_ago 30)" --end-time "$(iso_ago 0)" \
        --period 1800 --statistics Sum --query 'Datapoints[0].Sum' --output text
    done
  done
}

cmd_paths() {
  load_map
  local csv=$OUT-paths.csv t ib eb ia ea s_before s_after
  echo "== installing/starting iperf3 (hosts via SSM, Azure firewall via run-command)"
  ensure_iperf_hosts
  azfw "" 'command -v iperf3 >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iperf3 >/dev/null; }; command -v iperf3 || echo "NO iperf3"'

  s_before=$(aws_state)
  counters > "$OUT-paths.before"
  echo "== burst: 8 parallel flows each way to each host, 15 s at 2 Mbit/s per flow"
  azfw "A=$HOST_A; B=$HOST_B" '
for h in $A $B; do
  echo "-- $h Azure->AWS"; iperf3 -c $h -P 8 -t 15 -b 2M 2>&1 | grep -E "SUM.*(sender|receiver)" || echo "iperf3 failed"
  echo "-- $h AWS->Azure"; iperf3 -c $h -P 8 -t 15 -b 2M -R 2>&1 | grep -E "SUM.*(sender|receiver)" || echo "iperf3 failed"
done' | tee "$OUT-paths-iperf.txt"
  echo "waiting 30 s for Azure's counters to catch up..."
  sleep 30
  counters > "$OUT-paths.after"
  s_after=$(aws_state)

  echo "tunnel,aws_outside_ip,from_aws_MB,to_aws_MB,share_from_aws_pct,share_to_aws_pct" > "$csv"
  join "$OUT-paths.before" "$OUT-paths.after" | MAP="$MAP" awk '
    BEGIN { n = split(ENVIRON["MAP"], l, "\n"); for (i = 1; i <= n; i++) { split(l[i], p, " "); ip[p[1]] = p[2] } }
    { k[NR] = $1; din[NR] = $4 - $2; dout[NR] = $5 - $3; ti += din[NR]; to += dout[NR] }
    END { for (i = 1; i <= NR; i++)
            printf "%s,%s,%.1f,%.1f,%.0f,%.0f\n", k[i], ip[k[i]], din[i] / 1e6, dout[i] / 1e6,
                   ti ? 100 * din[i] / ti : 0, to ? 100 * dout[i] / to : 0 }' >> "$csv"
  rm -f "$OUT-paths.before" "$OUT-paths.after"
  echo; column -s, -t < "$csv"
  {
    echo "aws_state_before=$s_before"
    echo "aws_state_after=$s_after"
  } > "$OUT-paths.meta"
  echo; cat "$OUT-paths.meta"
  echo
  echo "ECMP is working if more than one tunnel carries traffic in each direction."
  echo "AWS-side per-tunnel bytes (CloudWatch, 5-min lag): run '$0 tunnels' in ~10 minutes."
  echo "saved: $csv"
}

# The tunnel the ping flow to host-a uses: a short ping flood, then the biggest counter delta
busiest_tunnel() {
  counters > "$OUT-busiest.before"
  azfw "DST=$HOST_A" 'ping -q -i 0.002 -s 1200 -c 5000 $DST | tail -2' >&2
  sleep 20
  counters > "$OUT-busiest.after"
  join "$OUT-busiest.before" "$OUT-busiest.after" |
    awk '{ d = ($4 - $2) + ($5 - $3); printf "  %s +%.1f MB\n", $1, d / 1e6 > "/dev/stderr"; if (d > best) { best = d; k = $1 } } END { print k }'
  rm -f "$OUT-busiest.before" "$OUT-busiest.after"
}

# N parallel 5/s pings from the Azure firewall. Each ping process has its own ICMP id, so
# ECMP hashes the flows across the 4 tunnels independently. Only per-flow gap summaries come
# back (Run Command keeps the last 4 KB); raw logs stay on the VM under /var/tmp.
PING_MULTI_BODY=$(cat <<'EOF2'
d=/var/tmp/cb-multi-$(date +%s); mkdir -p "$d"
for i in $(seq 1 "$N"); do ping -D -O -i 0.2 -w "$DUR" "$DST" > "$d/flow$i.txt" 2>&1 & done
wait
echo "raw logs on the VM: $d"
for i in $(seq 1 "$N"); do
  awk -v f="$i" '/bytes from/ { gsub(/\[|\]/, "", $1); t = $1 + 0
                    if (prev && t - prev > 0.5) { g = t - prev; if (g > mx) { mx = g; ms = prev } }
                    prev = t; r++ }
                 /no answer yet/ { m++ }
                 END { printf "flow %s replies=%d missed=%d max_gap_s=%.3f gap_start=%.3f\n", f, r, m, mx, ms }' "$d/flow$i.txt"
done
EOF2
)

summarize_multi() {  # $1 file with "flow ..." lines, $2 label
  awk -v label="$2" '/^flow / { n++; split($5, a, "="); g = a[2] + 0; if (g > 0.5) { k++; sum += g; if (g > mx) mx = g } }
      END { printf "%s: %d of %d flows had a gap (%.0f%%); longest gap %.2f s; mean gap of affected flows %.2f s\n",
                   label, k, n, n ? 100 * k / n : 0, mx, k ? sum / k : 0 }' "$1"
}

cmd_bgp_break() {
  load_map
  local out=$OUT-bgp-break active dur BREAK BREAK_DONE RESTORE   # lng, ping_pid: global (EXIT trap)
  echo "BGP peers now: $(peers)"
  echo "finding the tunnel the ping flow uses (ICMP flood to $HOST_A, then Azure counters)..."
  # Azure's per-connection byte counters lag by minutes, so "busiest tunnel" is unreliable.
  # Default: break TUNNEL (c0-t1) and let 16 parallel flows show what share of traffic it carried.
  active=${TUNNEL:-c0-t1}
  lng=cloudbridge-lng-aws-$active
  echo "busiest tunnel: $active (AWS outside IP $(ip_for_key "$active")) -> breaking BGP there"

  dur=$(( 60 + 20 + BROKEN + RECOVERY + 30 ))
  azfw "N=${FLOWS:-16}; DUR=$dur; DST=$HOST_A" "$PING_MULTI_BODY" > "$out-ping.txt" &
  ping_pid=$!
  trap 'az network local-gateway update -g "$RG" -n "$lng" --asn $AWS_ASN -o none 2>/dev/null; kill $ping_pid 2>/dev/null' EXIT
  echo "${FLOWS:-16} parallel 5/s pings from the Azure firewall to $HOST_A for ${dur}s; waiting 80 s for run-command to start..."
  echo "epoch_ms,phase,bgp_peers,az_connections,aws_tunnels" > "$out-state.csv"
  watch_state baseline 80 "$out-state.csv"

  BREAK=$(now_ms)
  az network local-gateway update -g "$RG" -n "$lng" --asn $BAD_ASN -o none
  BREAK_DONE=$(now_ms)
  echo "broke BGP on $active (peer ASN $AWS_ASN -> $BAD_ASN; update took $(( (BREAK_DONE - BREAK) / 1000 ))s), watching ${BROKEN}s..."
  watch_state broken "$BROKEN" "$out-state.csv"

  RESTORE=$(now_ms)
  az network local-gateway update -g "$RG" -n "$lng" --asn $AWS_ASN -o none
  echo "restored ASN $AWS_ASN, watching ${RECOVERY}s..."
  watch_state restored "$RECOVERY" "$out-state.csv"
  trap - EXIT

  echo "waiting for the remote ping to finish..."
  wait "$ping_pid" || true
  echo "break=$BREAK break_done=$BREAK_DONE restore=$RESTORE tunnel=$active bad_asn=$BAD_ASN" > "$out.meta"
  { grep '^flow ' "$out-ping.txt"; summarize_multi "$out-ping.txt" "BGP down on $active (IPsec up)"; } | tee "$out.txt"
  echo "saved: $out.txt $out-ping.txt $out-state.csv $out.meta"
}

cmd_instance_down() {
  load_map
  local inst=${1:-instance0} out vip dur BREAK   # ping_pid: global (EXIT trap)
  out=$OUT-instance-down-$inst
  case "$inst" in instance0|instance1) ;; *) echo "instance must be instance0 or instance1" >&2; exit 1 ;; esac
  vip=$(az network public-ip show -g "$RG" -n "cloudbridge-vpngw-$inst" --query ipAddress -o tsv)
  echo "resetting $inst ($vip): c${inst#instance}-t1 and c${inst#instance}-t2 terminate there"
  echo "BGP peers now: $(peers)"

  dur=$(( 60 + 20 + RESET_WATCH + 30 ))
  azfw "N=${FLOWS:-16}; DUR=$dur; DST=$HOST_A" "$PING_MULTI_BODY" > "$out-ping.txt" &
  ping_pid=$!
  trap 'kill $ping_pid 2>/dev/null' EXIT
  echo "${FLOWS:-16} parallel 5/s pings from the Azure firewall to $HOST_A for ${dur}s; waiting 80 s for run-command to start..."
  echo "epoch_ms,phase,bgp_peers,az_connections,aws_tunnels" > "$out-state.csv"
  watch_state baseline 80 "$out-state.csv"

  BREAK=$(now_ms)
  az network vnet-gateway reset -g "$RG" -n "$GW" --gateway-vip "$vip" --no-wait
  echo "reset requested for $inst, watching ${RESET_WATCH}s..."
  watch_state reset "$RESET_WATCH" "$out-state.csv"
  trap - EXIT

  echo "waiting for the remote ping to finish..."
  wait "$ping_pid" || true
  echo "break=$BREAK instance=$inst vip=$vip" > "$out.meta"
  {
    grep '^flow ' "$out-ping.txt"; summarize_multi "$out-ping.txt" "Azure gateway $inst reset"
    python3 - "$out-state.csv" "$BREAK" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
brk = int(sys.argv[2])
def down(r):  # BGP peers not Connected
    return [p.split("=")[0] for p in r["bgp_peers"].split() if not p.endswith("=Connected")]
first_down = next((r for r in rows if int(r["epoch_ms"]) >= brk and down(r)), None)
if not first_down:
    print("BGP peers never showed down in the samples.")
else:
    t0 = int(first_down["epoch_ms"])
    print(f"first peer down at break+{(t0 - brk) / 1000:.0f}s: {' '.join(down(first_down))}")
    back = next((r for r in rows if int(r["epoch_ms"]) > t0 and not down(r)), None)
    if back:
        print(f"all 4 peers Connected again at break+{(int(back['epoch_ms']) - brk) / 1000:.0f}s")
    else:
        print("peers had not all recovered by the end of the watch window")
PY
  } | tee "$out.txt"
  echo "saved: $out.txt $out-ping.txt $out-state.csv $out.meta"
}

cmd_mtu() {
  local out=$OUT-mtu.txt hosta fwa
  hosta=$(iid cloudbridge-app-host-a)
  fwa=$(iid cloudbridge-fw-a)
  # Largest ICMP payload that passes with Don't Fragment set (binary search); +28 = IP + ICMP
  local PMTU_BODY
  PMTU_BODY=$(cat <<'EOF'
echo "local MTU: $(ip -o link show | awk '$2 !~ /^lo/ {for (i = 1; i < NF; i++) if ($i == "mtu") {print $2, $(i+1); exit}}')"
lo=1000; hi=$HI
while [ $((hi - lo)) -gt 1 ]; do
  mid=$(( (lo + hi) / 2 ))
  if ping -M do -c 1 -W 1 -s $mid $DST >/dev/null 2>&1; then lo=$mid; else hi=$mid; fi
done
echo "largest DF payload to $DST: $lo  =>  path MTU $((lo + 28))"
echo "one byte more:"; ping -M do -c 1 -W 1 -s $((lo + 1)) $DST 2>&1 | grep -vE "^PING|^$" | head -3
command -v tracepath >/dev/null && { echo "tracepath:"; tracepath -n -m 8 $DST 2>&1 | tail -4; }
EOF
)
  {
    echo "== Configured MSS clamp (nftables 'mss' chain)"
    echo "-- AWS fw-a"; ssm "$fwa" "" 'nft list chain inet fw mss | grep maxseg' 60
    echo "-- Azure fw"; azfw "" 'nft list chain inet fw mss | grep maxseg'

    echo; echo "== Path MTU, Azure fw -> $HOST_A"
    azfw "DST=$HOST_A; HI=1473" "$PMTU_BODY"
    echo; echo "== Path MTU, $HOST_A -> Azure fw"
    ssm "$hosta" "DST=$AZFW_IP; HI=8973" "$PMTU_BODY" 300

    echo; echo "== TCP MSS, Azure -> AWS: SYN as sent by the Azure fw vs as received by host-a"
    local cid rx tx
    cid=$(ssm_send "$hosta" "SRC=$AZFW_IP" \
      'command -v tcpdump >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tcpdump >/dev/null; }
timeout 240 tcpdump -nn -v -c 1 -i any "src host $SRC and tcp dst port 80 and tcp[tcpflags] & tcp-syn != 0" 2>/dev/null' 300)
    sleep 10
    tx=$(azfw "DST=$HOST_A" '
timeout 100 tcpdump -nn -v -c 1 -i any "dst host $DST and tcp dst port 80 and tcp[tcpflags] & tcp-syn != 0" 2>/dev/null > /var/tmp/cb-syn-tx.txt &
sleep 2
for i in $(seq 1 12); do curl -s -o /dev/null --max-time 2 http://$DST/; sleep 5; done
wait; cat /var/tmp/cb-syn-tx.txt')
    rx=$(ssm_wait "$hosta" "$cid" 300)
    echo "sent by Azure fw   : $(grep -o 'mss [0-9]*' <<<"$tx" | head -1)"
    echo "received at host-a : $(grep -o 'mss [0-9]*' <<<"$rx" | head -1)"

    echo; echo "== TCP MSS, AWS -> Azure: SYN as sent by host-a vs as received by the Azure fw (TCP DNS, port 53)"
    cid=$(ssm_send "$hosta" "DST=$AZFW_IP" '
timeout 200 tcpdump -nn -v -c 1 -i any "dst host $DST and tcp dst port 53 and tcp[tcpflags] & tcp-syn != 0" 2>/dev/null > /var/tmp/cb-syn-tx.txt &
sleep 2
for i in $(seq 1 30); do dig +tcp +time=2 +tries=1 @$DST fw.az.cloudbridge.internal >/dev/null 2>&1; sleep 5; done
wait; cat /var/tmp/cb-syn-tx.txt' 300)
    rx=$(azfw "SRC=$HOST_A" 'timeout 120 tcpdump -nn -v -c 1 -i any "src host $SRC and tcp dst port 53 and tcp[tcpflags] & tcp-syn != 0" 2>/dev/null')
    tx=$(ssm_wait "$hosta" "$cid" 400)
    echo "sent by host-a     : $(grep -o 'mss [0-9]*' <<<"$tx" | head -1)"
    echo "received at Azure fw: $(grep -o 'mss [0-9]*' <<<"$rx" | head -1)"
  } | tee "$out"
  echo "saved: $out"
}

case "${1:-}" in
  check)         cmd_check ;;
  tunnels)       cmd_tunnels ;;
  paths)         cmd_paths ;;
  bgp-break)     cmd_bgp_break ;;
  instance-down) cmd_instance_down "${2:-instance0}" ;;
  mtu)           cmd_mtu ;;
  *) echo "usage: $0 check|tunnels|paths|bgp-break|instance-down [instance0|instance1]|mtu" >&2; exit 1 ;;
esac
