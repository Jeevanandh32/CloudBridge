#!/usr/bin/env bash
# Test 4: hub-and-spoke routing through the AWS inspection firewalls.
# Traffic: Azure hub firewall (10.20.241.4) -> VPN -> TGW (vpn table) -> inspection VPC ->
# fw-a / fw-b -> TGW (inspection table) -> app spoke test hosts, and back.
#
#   baseline   200 short curls to each test host, each from its own source port. Expect 100%.
#   break-a    TGW route table mistake: the spoke stops propagating into the inspection table,
#              so the firewalls have no route back to 10.10.0.0/20. Expect ~0%.
#   break-b    TGW appliance mode off on the inspection attachment: flows that cross AZs come
#              back through the other firewall, whose conntrack never saw the SYN. Expect a
#              partial failure, fw-invalid drops, and flow logs showing the asymmetric path.
#
# The scripts never run terraform apply: each break prints the exact command, you run it in
# another terminal, then press Enter. Results go to docs/runs/test4-*.
#
# Usage: ./test4-hub-firewall.sh baseline|break-a|break-b
set -euo pipefail
cd "$(dirname "$0")"

RG=cloudbridge-rg
AZFW=cloudbridge-fw
AZFW_IP=10.20.241.4
HOST_A=10.10.0.10
HOST_B=10.10.0.74
SPOKE_CIDR=10.10.0.0/20
N=200
OUT=../docs/runs/test4
AWS="aws --region us-east-2"
TF=../terraform
mkdir -p ../docs/runs

# ==================== helpers ====================

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
wrap() { printf "bash -s <<'CBEOF'\n%s\n%s\nCBEOF\n" "$1" "$2"; }

azfw() {  # run on the Azure firewall as root; Run Command keeps only the last 4 KB of output
  local msg
  msg=$(az vm run-command invoke -g "$RG" -n "$AZFW" --command-id RunShellScript \
    --scripts "$(wrap "$1" "$2")" --query 'value[0].message' -o tsv)
  awk '/^\[stdout\]/{f=1;next} /^\[stderr\]/{f=0} f' <<<"$msg"
  awk '/^\[stderr\]/{f=1;next} f' <<<"$msg" | grep -v '^$' | sed 's/^/  [azfw stderr] /' >&2 || true
}

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
ssm() {
  local cid
  cid=$(ssm_send "$1" "$2" "$3" "${4:-600}")
  ssm_wait "$1" "$cid" "$(( ${4:-600} + 120 ))"
}

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

tgw_rt() {  # TGW route table ID by role: spokes | vpn | inspection
  local id
  id=$($AWS ec2 describe-transit-gateway-route-tables \
    --filters "Name=tag:Name,Values=cloudbridge-tgw-rt-$1" "Name=state,Values=available" \
    --query 'TransitGatewayRouteTables[0].TransitGatewayRouteTableId' --output text)
  [ -n "$id" ] && [ "$id" != None ] || { echo "no TGW route table cloudbridge-tgw-rt-$1" >&2; return 1; }
  echo "$id"
}
routes() {  # $1 role
  echo "-- TGW route table '$1' ($(tgw_rt "$1"))"
  $AWS ec2 search-transit-gateway-routes --transit-gateway-route-table-id "$(tgw_rt "$1")" \
    --filters "Name=state,Values=active,blackhole" \
    --query 'Routes[].{cidr:DestinationCidrBlock,type:Type,state:State,via:TransitGatewayAttachments[0].ResourceType,paths:length(TransitGatewayAttachments || `[]`)}' \
    --output table
}
has_route() {  # $1 role, $2 cidr -> count of active routes for that exact CIDR
  $AWS ec2 search-transit-gateway-routes --transit-gateway-route-table-id "$(tgw_rt "$1")" \
    --filters "Name=route-search.exact-match,Values=$2" "Name=state,Values=active" \
    --query 'length(Routes)' --output text
}
appliance_mode() {
  $AWS ec2 describe-transit-gateway-vpc-attachments \
    --filters "Name=tag:Name,Values=cloudbridge-att-inspection" "Name=state,Values=available,modifying" \
    --query 'TransitGatewayVpcAttachments[0].Options.ApplianceModeSupport' --output text
}

# 200 curls per host from the Azure firewall, 20 in parallel, each from a fixed source port
# (host-a: BASE.., host-b: BASE+1000..), so every flow hashes independently and can be found
# again in the flow logs. Full results stay on the VM; the summary and failed ports come back.
CURL_BODY=$(cat <<'EOF'
run() {
  code=$(curl -s -o /dev/null --connect-timeout 1 --max-time 2 --local-port "$2" -w '%{http_code}' "http://$1/" 2>/dev/null)
  echo "$1 $2 $? ${code:-000}"
}
export -f run
f=/var/tmp/cb-curls-$LABEL.txt
{ for i in $(seq 0 $((N - 1))); do echo "$A $((BASE + i))"; echo "$B $((BASE + 1000 + i))"; done; } |
  xargs -P 20 -n 2 bash -c 'run "$0" "$1"' > "$f"
for h in $A $B; do
  awk -v h=$h '$1 == h { n++; if ($3 == 0 && $4 == 200) ok++; else bad[++nb] = $2; rc[$3]++ }
    END { printf "RESULT %s ok=%d total=%d pct=%.1f exit_codes:", h, ok, n, n ? 100 * ok / n : 0
          for (c in rc) printf " %s=%d", c, rc[c]; print ""
          if (nb && nb <= 120) { printf "FAILPORTS %s", h; for (i = 1; i <= nb; i++) printf " %s", bad[i]; print "" } }' "$f"
done
EOF
)

run_curls() {  # $1 label -> prints summary, saves docs/runs/test4-<label>.txt
  local label=$1 base start end
  base=$(( 10000 + ( $(date +%s) / 60 % 9 ) * 2000 ))   # ports 10000-27199, never the ephemeral range
  start=$(now_ms)
  echo "running $N curls to each of $HOST_A and $HOST_B from the Azure firewall (source ports from $base)..."
  azfw "LABEL=$label; N=$N; BASE=$base; A=$HOST_A; B=$HOST_B" "$CURL_BODY" > "$OUT-$label.raw"
  end=$(now_ms)
  {
    echo "label=$label start_ms=$start end_ms=$end base_port=$base"
    awk '/^RESULT/ { printf "%-12s %s/%s ok  (%s%%)   curl exit codes:%s\n", $2, substr($3,4), substr($4,7), substr($5,5), substr($0, index($0, "exit_codes:") + 11) }' "$OUT-$label.raw"
    echo "(exit 0 = ok, 28 = timeout, 7 = refused, 45 = local port busy)"
  } | tee "$OUT-$label.txt"
  CURL_START=$start; CURL_END=$end; CURL_BASE=$base
}

nft_counters() {  # forward chain counters on both AWS firewalls
  local f
  for f in cloudbridge-fw-a cloudbridge-fw-b; do
    echo "-- $f"
    ssm "$(iid $f)" "" 'nft list chain inet fw forward | grep -E "counter|policy"' 120
  done
}

# ==================== subcommands ====================

cmd_baseline() {
  echo "appliance mode on the inspection attachment: $(appliance_mode)"
  echo "inspection table has $SPOKE_CIDR: $(has_route inspection $SPOKE_CIDR) route(s)"
  run_curls baseline
}

cmd_break_a() {
  local out=$OUT-break-a-evidence.txt
  {
    echo "== Before"
    routes inspection
  } | tee "$out"

  pause "cd terraform/aws/spoke-app && terraform plan -var propagate_to_inspection=false -out=break-a.tfplan && terraform apply break-a.tfplan"

  local i=0
  until [ "$(has_route inspection $SPOKE_CIDR)" = 0 ]; do
    i=$((i + 1)); [ $i -gt 12 ] && { echo "$SPOKE_CIDR is still in the inspection table; did the apply run?" >&2; exit 1; }
    sleep 5
  done
  echo "$SPOKE_CIDR is gone from the inspection table"

  echo "== nftables counters before the curls" | tee -a "$out"
  nft_counters | tee -a "$out"
  run_curls break-a
  {
    echo
    echo "== Evidence 1: the inspection table has no route back to the spoke"
    routes inspection
    echo "   inspection table, exact match $SPOKE_CIDR: $(has_route inspection $SPOKE_CIDR) active route(s)  <- 0 = the mistake"
    echo
    echo "== Evidence 2: the vpn table still sends $SPOKE_CIDR to the inspection VPC (and BGP still advertises it to Azure)"
    routes vpn
    echo
    echo "== Evidence 3: nftables counters after the curls"
    echo "   The 'ip saddr 10.0.0.0/8 ct state new' accept counter grew: the firewalls forwarded"
    echo "   the SYNs, then the TGW dropped them (no route in the inspection table). Nothing hit"
    echo "   fw-invalid or fw-drop: the firewall is not the problem."
    nft_counters
  } | tee -a "$out"

  pause "cd terraform/aws/spoke-app && terraform plan -out=restore.tfplan && terraform apply restore.tfplan   # RESTORE (propagate_to_inspection back to true)"
  i=0
  until [ "$(has_route inspection $SPOKE_CIDR)" = 1 ]; do
    i=$((i + 1)); [ $i -gt 12 ] && { echo "$SPOKE_CIDR still missing; check the restore apply" >&2; exit 1; }
    sleep 5
  done
  echo "$SPOKE_CIDR is back in the inspection table; checking traffic"
  run_curls break-a-restored
  echo "saved: $OUT-break-a.txt $out $OUT-break-a-restored.txt"
}

# Sample conntrack on a firewall every 3 s during the curls; keep the last state per flow
CONNTRACK_BODY=$(cat <<'EOF'
: > /var/tmp/cb-ct.txt
end=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$end" ]; do
  conntrack -L -p tcp -s $SRC --dport 80 2>/dev/null >> /var/tmp/cb-ct.txt; sleep 3
done
awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^sport=/) { p = substr($i, 7); break }
       st[p] = $4; if ($0 ~ /UNREPLIED/) un[p] = 1; line[p] = $0 }
     END { for (p in st) { c[st[p] ((p in un) ? "[UNREPLIED]" : "")]++; n++ }
           printf "flows seen: %d   by last state:", n; for (s in c) printf " %s=%d", s, c[s]; print ""
           k = 0; for (p in un) if (k++ < 3) print "  e.g. " line[p] }' /var/tmp/cb-ct.txt
EOF
)

# Flow log records for this run's source ports, matched to the firewall ENIs
flowlogs() {  # $1 = file to write the per-flow CSV to
  local bucket acct vpc flid eni_map since deadline keys days day newest
  bucket=$(terraform -chdir="$TF/aws/hub" output -raw flowlog_bucket 2>/dev/null ||
    $AWS s3api list-buckets --query "Buckets[?starts_with(Name, 'cloudbridge-flowlogs-')].Name | [0]" --output text)
  acct=$($AWS sts get-caller-identity --query Account --output text)
  vpc=$($AWS ec2 describe-vpcs --filters Name=tag:Name,Values=cloudbridge-inspection --query 'Vpcs[0].VpcId' --output text)
  flid=$($AWS ec2 describe-flow-logs --filter "Name=resource-id,Values=$vpc" --query 'FlowLogs[0].FlowLogId' --output text)
  echo "bucket $bucket, inspection VPC $vpc, flow log $flid"

  # ENI -> label: the two firewalls and the TGW attachment ENIs (one per AZ)
  eni_map=$OUT-break-b-enis.txt
  {
    $AWS ec2 describe-instances --filters "Name=tag:Name,Values=cloudbridge-fw-a,cloudbridge-fw-b" "Name=instance-state-name,Values=running" \
      --query 'Reservations[].Instances[].[NetworkInterfaces[0].NetworkInterfaceId, Tags[?Key==`Name`]|[0].Value]' --output text |
      sed 's/cloudbridge-//'
    $AWS ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc" "Name=interface-type,Values=transit_gateway" \
      --query 'NetworkInterfaces[].[NetworkInterfaceId, AvailabilityZone]' --output text | awk '{print $1, "tgw-eni-" $2}'
  } > "$eni_map"
  cat "$eni_map"

  # VPC flow logs reach S3 in ~5-10 min (60 s aggregation + delivery). Wait for a file written
  # at least 2 min after the curls ended, so their records are all in.
  since=$(( CURL_START / 1000 - 120 ))
  deadline=$(( $(date +%s) + 900 ))
  days=$(python3 -c "import datetime as d,sys; t=int(sys.argv[1]); print(' '.join(sorted({d.datetime.fromtimestamp(x, d.timezone.utc).strftime('%Y/%m/%d') for x in (t, t + 7200)})))" "$since")
  echo "waiting for flow log files in s3://$bucket (up to 15 min)..."
  while :; do
    keys=""
    for day in $days; do
      keys="$keys$($AWS s3api list-objects-v2 --bucket "$bucket" --prefix "AWSLogs/$acct/vpcflowlogs/us-east-2/$day/" \
        --query "Contents[?contains(Key, '$flid')].[Key, LastModified]" --output text 2>/dev/null | grep -v '^None' || true)"$'\n'
    done
    newest=$(awk '{print $2}' <<<"$keys" | sort | tail -1)
    if [ -n "$newest" ] && python3 -c "import datetime as d,sys; t=d.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp(); sys.exit(0 if t >= int(sys.argv[2])/1000 + 120 else 1)" "$newest" "$CURL_END"; then
      break
    fi
    [ "$(date +%s)" -lt "$deadline" ] || { echo "no complete flow log file yet; rerun later: the records will still be in S3 for 7 days" >&2; break; }
    sleep 30
  done

  local tmp
  tmp=$(mktemp -d)
  awk '{print $1, $2}' <<<"$keys" | while read -r key lm; do
    [ -n "$key" ] || continue
    python3 -c "import datetime as d,sys; t=d.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp(); sys.exit(0 if t >= int(sys.argv[2]) else 1)" "$lm" "$since" || continue
    $AWS s3 cp "s3://$bucket/$key" "$tmp/$(basename "$key")" --quiet
  done

  python3 - "$tmp" "$eni_map" "$AZFW_IP" "$HOST_A" "$HOST_B" "$CURL_BASE" "$N" "$OUT-break-b.raw" "$1" <<'PY'
import csv, glob, gzip, sys
tmp, eni_file, src, ha, hb, base, n, raw, out = sys.argv[1:]
base, n = int(base), int(n)
eni = dict(l.split() for l in open(eni_file) if l.strip())
ports = {}                                   # source port -> host
for i in range(n):
    ports[base + i] = ha
    ports[base + 1000 + i] = hb
failed = set()
for l in open(raw):
    if l.startswith("FAILPORTS"):
        failed.update(int(p) for p in l.split()[2:])
    elif l.startswith("RESULT") and "ok=0 " in l:
        h = l.split()[1]
        failed.update(p for p, hh in ports.items() if hh == h)
req, rep, rejects = {}, {}, 0
for f in glob.glob(f"{tmp}/*.gz"):
    with gzip.open(f, "rt") as fh:
        hdr = fh.readline().split()
        for line in fh:
            r = dict(zip(hdr, line.split()))
            if r.get("protocol") != "6":
                continue
            try:
                sp, dp = int(r["srcport"]), int(r["dstport"])
            except ValueError:
                continue
            who = eni.get(r["interface-id"], r["interface-id"])
            if r["srcaddr"] == src and dp == 80 and sp in ports:
                req.setdefault(sp, set()).add(who)
            elif r["dstaddr"] == src and sp == 80 and dp in ports:
                rep.setdefault(dp, set()).add(who)
                rejects += r.get("action") == "REJECT"
fw = lambda s: sorted(x for x in s if x.startswith("fw-"))
rows, sym, asym, unseen = [], 0, 0, 0
for p in sorted(ports):
    a, b = fw(req.get(p, set())), fw(rep.get(p, set()))
    kind = "not-in-logs" if not a and not b else ("symmetric" if a == b else "ASYMMETRIC")
    sym += kind == "symmetric"; asym += kind == "ASYMMETRIC"; unseen += kind == "not-in-logs"
    tgw = sorted(x for x in req.get(p, set()) | rep.get(p, set()) if x.startswith("tgw-"))
    rows.append([p, ports[p], "+".join(a) or "-", "+".join(b) or "-", "+".join(tgw) or "-", kind,
                 "fail" if p in failed else "ok"])
with open(out, "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["src_port", "host", "request_via", "reply_via", "tgw_enis", "path", "curl"])
    w.writerows(rows)
print(f"flows: {len(rows)}  symmetric: {sym}  ASYMMETRIC: {asym}  not in logs yet: {unseen}")
for kind in ("symmetric", "ASYMMETRIC"):
    sel = [r for r in rows if r[5] == kind]
    if sel:
        f = sum(r[6] == "fail" for r in sel)
        print(f"  {kind:10s}: {len(sel):3d} flows, {f:3d} curl failures")
print(f"reply records with action REJECT: {rejects}")
print("  (expected 0: the firewall security group accepts 10/8, so the VPC logs the stray reply")
print("   as ACCEPT on the wrong firewall's ENI; nftables drops it inside the VM as fw-invalid)")
for r in [r for r in rows if r[5] == "ASYMMETRIC"][:5]:
    print(f"  e.g. port {r[0]} -> {r[1]}: request via {r[2]}, reply via {r[3]}, curl {r[6]}")
PY
  rm -rf "$tmp"
}

cmd_break_b() {
  local out=$OUT-break-b-evidence.txt since cid_a cid_b fwa fwb
  echo "appliance mode now: $(appliance_mode)"
  pause "cd terraform/aws/hub && terraform plan -var appliance_mode=disable -out=break-b.tfplan && terraform apply break-b.tfplan"

  local i=0
  until [ "$(appliance_mode)" = disable ]; do
    i=$((i + 1)); [ $i -gt 24 ] && { echo "appliance mode is still $(appliance_mode); did the apply run?" >&2; exit 1; }
    sleep 5
  done
  echo "appliance mode is now disable; waiting 30 s for the TGW to settle"
  sleep 30

  fwa=$(iid cloudbridge-fw-a); fwb=$(iid cloudbridge-fw-b)
  since=$(date +%s)
  # conntrack samplers run on both firewalls while the curls run (SSM is asynchronous)
  cid_a=$(ssm_send "$fwa" "SRC=$AZFW_IP; DUR=240" "$CONNTRACK_BODY" 400)
  cid_b=$(ssm_send "$fwb" "SRC=$AZFW_IP; DUR=240" "$CONNTRACK_BODY" 400)
  run_curls break-b
  {
    echo
    echo "== Evidence 1: invalid-state drops on each firewall since the break"
    for f in "fw-a $fwa" "fw-b $fwb"; do
      set -- $f
      echo "-- $1"
      ssm "$2" "SINCE=$since" '
echo "fw-invalid log lines: $(journalctl -k --since "@$SINCE" --no-pager | grep -c "fw-invalid ")"
echo "fw-drop    log lines: $(journalctl -k --since "@$SINCE" --no-pager | grep -c "fw-drop ")"
journalctl -k --since "@$SINCE" --no-pager | grep "fw-invalid " | tail -2 | cut -c1-260
nft list chain inet fw forward | grep -E "invalid|fw-drop"' 120
    done
    echo "   A reply (SYN-ACK) that reaches the firewall which never saw the SYN is 'ct state invalid'."
    echo
    echo "== Evidence 2: conntrack on each firewall during the curls (Azure fw -> port 80)"
    echo "   SYN_SENT [UNREPLIED] = this firewall forwarded the SYN but the reply went to the other one"
    echo "-- fw-a"; ssm_wait "$fwa" "$cid_a" 500
    echo "-- fw-b"; ssm_wait "$fwb" "$cid_b" 500
    echo
    echo "== Evidence 3: inspection VPC flow logs (S3): which firewall saw the request vs the reply"
    flowlogs "$OUT-break-b-flows.csv"
  } | tee "$out"

  pause "cd terraform/aws/hub && terraform plan -out=restore.tfplan && terraform apply restore.tfplan   # RESTORE (appliance_mode back to enable)"
  i=0
  until [ "$(appliance_mode)" = enable ]; do
    i=$((i + 1)); [ $i -gt 24 ] && { echo "appliance mode is still $(appliance_mode); check the restore apply" >&2; exit 1; }
    sleep 5
  done
  echo "appliance mode is enable again; checking traffic"
  sleep 30
  run_curls break-b-restored
  echo "saved: $OUT-break-b.txt $out $OUT-break-b-flows.csv $OUT-break-b-restored.txt"
}

case "${1:-}" in
  baseline) cmd_baseline ;;
  break-a)  cmd_break_a ;;
  break-b)  cmd_break_b ;;
  *) echo "usage: $0 baseline|break-a|break-b" >&2; exit 1 ;;
esac
