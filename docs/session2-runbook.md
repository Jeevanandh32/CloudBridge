# Session 2 runbook: Test 5 and Test 6 (with clusters)

Session 2 builds layers 1–7 and 9 from [`plan.md`](plan.md): everything from
[Session 1](session1-runbook.md) plus EKS and AKS. Test 5 is about pod IPs (capacity on EKS,
routable vs overlay pod networks across the VPN). Test 6 is about traffic control
(NetworkPolicy in both clusters, forced egress through the firewalls, the inbound DNAT design).

| | |
|---|---|
| Layers | Session 1 layers + `aws/eks`, `azure/aks` |
| Tests | Test 5 (pod networking across clouds), Test 6 (Kubernetes traffic control) |
| Time | About 5–6 h: 1 h build, 4 h of tests (two node-group rolls take 15–25 min each), 30 min teardown |
| Cost | About **$0.85–1.00/hr**, so about **$5** for the session ([breakdown](#session-cost)) |
| Scripts | `k8s/deploy.sh`, `tests/test5-pod-networking.sh`, `tests/test6-traffic-control.sh`, `tests/inventory.sh` |
| Results | `docs/runs/test5-*`, `docs/runs/test6-*` |

**Who runs what:** you run every `terraform apply` and `destroy`. The test scripts never run
terraform: when a test needs a layer change, the script prints the exact command and waits for
you to press Enter. Unlike Session 1, the scripts **do change the clusters** (test pods, a pause
deployment, ENIConfigs, NetworkPolicies) and, in Test 6 Part B, **the firewalls' live nftables
rules**. Each firewall change is undone at the end of its subcommand, by an EXIT trap if the
script dies, and by a reboot (nothing is written to `/etc/nftables.conf`).

**Addresses used below:**

| What | Value |
|---|---|
| EKS nodes / default pod IPs | `10.10.0.0/26` (2a), `10.10.0.64/26` (2b) |
| EKS custom-networking pod subnets | `10.10.64.0/19` (2a), `10.10.96.0/19` (2b) |
| ALB | public subnets `10.10.4.0/24`, `10.10.5.0/24` |
| AWS firewalls | fw-a `10.10.240.40`, fw-b `10.10.240.56` (SSM) |
| AKS node | `10.20.0.x` in `10.20.0.0/22`; pods in overlay `10.244.0.0/16` |
| AKS internal LB | `10.20.4.10` (DNAT target of the Azure firewall) |
| Azure firewall | `10.20.241.4`, public IP from `terraform -chdir=terraform/azure/hub output -raw fw_public_ip` |
| Private Endpoint (blob) | `10.20.5.0/27` |

---

## 0. Prerequisites

Everything from [Session 1 §0](session1-runbook.md#0-prerequisites), plus:

```bash
kubectl version --client          # >= 1.33 (kustomize built in)
helm version                      # AWS Load Balancer Controller
docker info >/dev/null && echo ok # builds the app image (linux/amd64)
tests/inventory.sh                # should end with "CLEAN" before you start
```

Git-ignored files you need, on top of Session 1's:
- `terraform/aws/eks/terraform.tfvars` and `terraform/azure/aks/terraform.tfvars`, each with
  `admin_cidrs = ["<YOUR_PUBLIC_IP>/32"]` (copy the `.example` files;
  `curl -s https://checkip.amazonaws.com`). The EKS and AKS APIs only accept these IPs.

---

## 1. Apply order

```
t=0      azure/hub ───────────────────────────── (30–45 min, VPN gateway) ──┐
t=0      aws/hub ── aws/spoke-app ── aws/eks (15 min)                       │
                                                                            ▼
t≈45     azure/spoke-aks ── connectivity/vpn ──┬── ops
                                               └── azure/aks (10 min)
```

1. **Session 1 layers**, exactly as in [Session 1 §1](session1-runbook.md#1-apply-order):
   `azure/hub` first, `aws/hub` and `aws/spoke-app` in parallel, then `azure/spoke-aks`,
   `connectivity/vpn` and `ops`. Run the same checks (`tests/test3-hybrid-routing.sh check`).
   The Session 1 test hosts are not needed, and they take IPs in the `/26` node subnets that
   Test 5 counts. Before applying `aws/spoke-app`, put `enable_test_hosts = false` in
   `terraform/aws/spoke-app/terraform.tfvars` (git-ignored). Use the tfvars file, not `-var`,
   so the `-var enable_secondary_cidr=true` apply in Test 5 doesn't bring the hosts back.
2. **`aws/eks`**, as soon as `aws/spoke-app` is done (it doesn't need Azure):
   ```bash
   cd terraform/aws/eks && terraform init -backend-config=../../backend.hcl
   terraform plan -out=layer.tfplan && caffeinate -i terraform apply layer.tfplan
   ```
3. **`azure/aks`**, after `azure/spoke-aks` (it needs the spoke subnets and the UDR):
   ```bash
   cd terraform/azure/aks && terraform init -backend-config=../../backend.hcl
   terraform plan -out=layer.tfplan && caffeinate -i terraform apply layer.tfplan
   ```
   AKS with `outboundType: userDefinedRouting` builds through the hub firewall, so the
   firewall must be up and allow-all (it is by default).

### Kubeconfig and the Load Balancer Controller

```bash
aws eks update-kubeconfig --region us-east-2 --name cloudbridge-eks --alias cloudbridge-eks
az aks get-credentials -g cloudbridge-rg -n cloudbridge-aks --context cloudbridge-aks --overwrite-existing

helm repo add eks https://aws.github.io/eks-charts && helm repo update eks
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller --version 3.6.0 \
  -n kube-system --kube-context cloudbridge-eks --set clusterName=cloudbridge-eks \
  --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-2 --set vpcId=$(terraform -chdir=terraform/aws/eks output -raw vpc_id)
```

**Check the clusters:**
```bash
kubectl --context cloudbridge-eks get nodes -L topology.kubernetes.io/zone,cloudbridge.io/pod-ip-mode \
  -o custom-columns='NODE:.metadata.name,IP:.status.addresses[0].address,MAX_PODS:.status.capacity.pods,MODE:.metadata.labels.cloudbridge\.io/pod-ip-mode'
kubectl --context cloudbridge-aks get nodes -o wide
kubectl --context cloudbridge-eks -n kube-system get ds aws-node -o jsonpath='{.spec.template.spec.containers[0].env}' | jq -r '.[] | select(.name | test("SNAT|PREFIX|CUSTOM")) | "\(.name)=\(.value)"'
kubectl --context cloudbridge-aks -n kube-system get ds cilium
```

| Where | Expected |
|---|---|
| EKS nodes | 2 × Ready, one per AZ, `MAX_PODS` 17, mode `secondary-ip`, IPs in `10.10.0.0/26` and `10.10.0.64/26` |
| aws-node env | `AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS=10.20.0.0/16`, `ENABLE_PREFIX_DELEGATION=false`, `AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=false` |
| AKS | 1 node Ready with a `10.20.0.x` IP; `cilium` DaemonSet 1/1 |

---

## 2. Deploy the app

```bash
k8s/deploy.sh            # = all: build once, push to ECR and ACR, deploy both overlays
```

`k8s/deploy.sh` reads the registries from `terraform/aws/eks` (`ecr_repository_url`) and
`terraform/azure/aks` (`acr_login_server`), builds `app/` for linux/amd64, pushes `v1` to
both, renders `k8s/overlays/aws` and `k8s/overlays/azure`, applies them, and waits for the
rollouts. Other forms: `k8s/deploy.sh aws|azure|coredns`, `--no-build`, `--dry-run` (render only).

What the overlays do:
- **`overlays/aws`**: the public ALB Ingress (IP targets, public subnets). The v1
  internal NLB and the `backend.cloudbridge.internal` URL are gone: the frontend calls
  `http://backend:8080`. Test 1 (Session 3) may bring them back; see the comment in the file.
- **`overlays/azure`**: the frontend Service is an **internal** LB on `10.20.4.10` in the
  `ilb` subnet. There is no public IP; the Azure firewall DNATs its public IP port 80 to it.
- **`overlays/aws-tuned`**: v1 only (node-failure timers). It still renders.

### EKS CoreDNS forwarding (set by Terraform)

EKS keeps the VPC resolver for everything, which knows `cloudbridge.internal` but not Azure's
private zones. [`k8s/coredns-eks/coredns-configmap.yaml`](../k8s/coredns-eks/coredns-configmap.yaml)
adds a server block that forwards `az.cloudbridge.internal`,
`privatelink.blob.core.windows.net` **and `blob.core.windows.net`** to the AWS firewalls
(`10.10.240.40`, `10.10.240.56`), which forward to the Azure firewall. The third zone is
needed because a pod asks for `<account>.blob.core.windows.net`: whoever answers that query
follows the CNAME to `privatelink…` itself, and the VPC resolver would return the public IP.

The `aws/eks` layer sets this through the CoreDNS add-on's `configuration_values`
([`k8s/coredns-eks/addon-configuration.json`](../k8s/coredns-eks/addon-configuration.json)), so it is
in place as soon as the cluster exists, and add-on updates keep it. `k8s/deploy.sh coredns` is only
a fallback, for when you edit the ConfigMap by hand. Normally you don't need it, and the next add-on
update would undo a hand edit anyway.

AKS needs no CoreDNS change: the spoke VNet's DNS server is the Azure firewall's dnsmasq,
which forwards `cloudbridge.internal` to AWS.

---

## 3. Checks

**Pods running:**
```bash
kubectl --context cloudbridge-eks -n cloudbridge get pods -o wide     # 3 backend + 3 frontend, Running
kubectl --context cloudbridge-aks -n cloudbridge get pods -o wide
kubectl --context cloudbridge-aks -n cloudbridge get svc frontend      # TYPE LoadBalancer, EXTERNAL-IP 10.20.4.10
```

**Azure inbound (internet → firewall DNAT → ILB → pods):**
```bash
FWPIP=$(terraform -chdir=terraform/azure/hub output -raw fw_public_ip)
curl -s http://$FWPIP/health          # {"status":"ok",...,"cloud":"azure"}
curl -s http://$FWPIP/                # frontend + backend pod names
```

**AWS inbound (ALB):**
```bash
ALB=$(kubectl --context cloudbridge-eks -n cloudbridge get ingress frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s http://$ALB/health            # "cloud":"aws" (a new ALB needs 2–3 min)
```

**Cross-cloud DNS from pods** (also part of `tests/test5-pod-networking.sh private`):
```bash
kubectl --context cloudbridge-aks run dnscheck --rm -i --restart=Never --image=nicolaka/netshoot:v0.13 -- dig +short fw-a.cloudbridge.internal
# 10.10.240.40   (CoreDNS -> node resolver = Azure fw dnsmasq -> AWS fw -> VPC resolver)
kubectl --context cloudbridge-eks run dnscheck --rm -i --restart=Never --image=nicolaka/netshoot:v0.13 -- dig +short fw.az.cloudbridge.internal
# 10.20.241.4    (CoreDNS stanza -> AWS fw -> Azure fw -> 168.63.129.16)
```

**Private access** (both in `tests/test5-pod-networking.sh private`, saved to
`docs/runs/test5-private.txt`):
- **An EKS pod reads the Azure blob through the Private Endpoint.**
  - `dig <account>.blob.core.windows.net` returns a CNAME to `privatelink.blob.core.windows.net`
    and an A record in `10.20.5.0/27`.
  - `curl` with a 15-minute read-only SAS returns
    `hello from Azure Blob over Private Endpoint`, with `remote_ip` `10.20.5.x`.
  - The SAS is created with `az storage blob generate-sas --auth-mode key`. It is passed to
    curl and never printed.
  - Path: EKS → TGW → AWS fw → VPN → Azure fw (SNAT, so the PE reply comes back the same way)
    → PE.
- **An AKS pod reads S3 through the interface endpoint, over the VPN.**
  - `curl https://<probe_bucket>.<s3_interface_dns without "*.">/hello.txt` returns
    `hello from AWS S3 over PrivateLink`, with `remote_ip` in `10.10.0.0/26`.
  - The same object through the public S3 endpoint returns 403: the bucket policy requires
    `aws:SourceVpce`.
  - Inputs: `terraform -chdir=terraform/aws/spoke-app output s3_interface_dns` and
    `terraform -chdir=terraform/aws/spoke-app output probe_bucket`.

---

## 4. Test 5: pod networking across clouds

All results go to `docs/runs/test5-*`. Run the subcommands in this order. `capacity`,
`prefix` and `custom` each leave the pause pods scaled to 0 at the end (`KEEP=1` keeps them).

### 4a. Capacity with default settings: the per-node limit
```bash
tests/test5-pod-networking.sh capacity           # label = the nodes' pod-ip-mode (secondary-ip)
```
- Creates namespace `cb-capacity` with a `pause` deployment (1m CPU, 4 Mi requests, so CPU and
  memory never limit scheduling), then scales it through `STEPS` (default
  `10 20 30 40 50 60 80 100 120 150 180 220`).
- Each step waits until the counts settle, then records: running, unschedulable (Pending, no
  node), scheduled-but-no-IP (ContainerCreating), all pods per node, and
  `AvailableIpAddressCount` for every node and pod subnet.
- It also records the first stuck pod with its event: `FailedScheduling` or
  `FailedCreatePodSandBox`.
- It stops after two steps that add no running pods.
- Files: `test5-capacity-secondary-ip.txt` (with ENIs, secondary IPs and prefixes per node)
  and `.csv`.

**Expect:**
- Each node tops out at **17 pods**, all pods counted, including `aws-node`, `kube-proxy`,
  CoreDNS, the LB controller and the app. That is 3 ENIs × (6 − 1) + 2.
- The rest stay **Pending** with `0/2 nodes are available: 2 Too many pods`.
- The /26 subnets still have free IPs, so the limit is per node, not per subnet.

### 4b. Fix 1: prefix delegation, then the subnets run out
```bash
tests/test5-pod-networking.sh prefix
```
1. Prints the command for you to run:
   ```bash
   cd terraform/aws/eks && terraform plan -var enable_prefix_delegation=true -out=prefix.tfplan && caffeinate -i terraform apply prefix.tfplan
   ```
   The apply changes the VPC CNI config **and** rolls the Spot node group: it creates a new
   launch template version, and the new nodes launch with max-pods 110.
2. Waits until both nodes carry `cloudbridge.io/pod-ip-mode=prefix` (10–25 min), then reruns
   `capacity prefix`.

**Expect:**
- `MAX_PODS` 110.
- Subnet free counts now fall in steps of 16: each ENI takes whole `/28` prefixes.
- The new limit is the **subnet**. A `/26` holds only 4 aligned `/28`s, and the node's own
  IPs, the ENI primaries and the EKS control-plane ENIs already break some of them up.
- Pods stay **ContainerCreating** with `FailedCreatePodSandBox … failed to assign an IP
  address to container`. The node has room in max-pods, but the CNI can't get another prefix.

Keep passing `-var enable_prefix_delegation=true` on every later `aws/eks` apply, or set it in
`terraform.tfvars`, until the restore.

### 4c. Fix 2: secondary CIDR and custom networking
```bash
tests/test5-pod-networking.sh custom
```
1. Prints these commands for you to run:
   ```bash
   cd terraform/aws/spoke-app && terraform plan -var enable_secondary_cidr=true -out=secondary.tfplan && terraform apply secondary.tfplan
   cd ../eks && terraform plan -var enable_prefix_delegation=true -out=outputs.tfplan && terraform apply outputs.tfplan
   ```
   - The first adds `10.10.64.0/18` and the two pod subnets, and the TGW route and BGP
     advertisement for them.
   - The second changes nothing in AWS. It fills the `eniconfig_subnets` output.
2. Applies the ENIConfigs (saved to `test5-eniconfig.yaml`):
   [`k8s/eniconfig/render.sh`](../k8s/eniconfig/render.sh) fills
   [`eniconfig.yaml.tmpl`](../k8s/eniconfig/eniconfig.yaml.tmpl) once per AZ.
   - `metadata.name` is the AZ (`us-east-2a`, `us-east-2b`).
   - `spec.subnet` comes from `eniconfig_subnets`.
   - `spec.securityGroups` is `[node_security_group_id]`.
   - To do it by hand: `k8s/eniconfig/render.sh | kubectl --context cloudbridge-eks apply -f -`.
3. Prints:
   ```bash
   cd terraform/aws/eks && terraform plan -var enable_prefix_delegation=true -var enable_custom_networking=true -out=custom.tfplan && caffeinate -i terraform apply custom.tfplan
   ```
   This rolls the nodes again, automatically. The ENIConfigs must exist before the new nodes
   start, which is why step 2 comes first. There is no manual node recycle.
4. Waits for `pod-ip-mode=prefix-custom-net`, lists the app pod IPs
   (`test5-custom-app-pods.txt`), and reruns `capacity prefix-custom-net`.

**Expect:**
- Pod IPs in `10.10.64.0/19` and `10.10.96.0/19`, which is `10.10.64.0/18`. Nodes keep their
  `/26` IPs.
- `MAX_PODS` 110, and the run ends at the step limit or at max-pods, not at the subnets.
- The node subnets' free count stops moving: the primary ENI carries no pods.
- Without prefix delegation, custom networking alone gives 12 pods per node, because the
  primary ENI is lost to pods. The node may still report 17.

### 4d. Cross-cloud pod traffic
```bash
tests/test5-pod-networking.sh xcloud
```
This starts `cb-nsh` (netshoot running an `iperf3 -s` listener on 5201) in both clusters,
plus a host-network netshoot on the AKS node for tcpdump. Results: `test5-xcloud.txt`.

| # | Flow | Expect | tcpdump on the far side |
|---|---|---|---|
| 1 | AKS pod → EKS pod IP (ping, TCP 5201, HTTP to an EKS backend pod) | **works** | in the EKS pod: the source is the **AKS node IP** `10.20.0.x`, not `10.244.x`; Cilium SNATs traffic leaving the overlay |
| 2 | EKS pod → AKS pod IP `10.244.x` | **fails** (timeout) | on the AKS node: 0 packets. The TGW longest-prefix match for it is `0.0.0.0/0` towards the firewall NAT; `10.244.0.0/16` is in no route table and not advertised over BGP |
| 3 | EKS pod → `http://10.20.4.10/` (AKS internal LB) | **works** | on the AKS node: the source is the **EKS pod IP**, because the VPC CNI leaves `10.20.0.0/16` out of its SNAT |

This works with either EKS pod mode. After 4c the EKS pod IP is in `10.10.64.0/18`, which
Azure learns over BGP once the secondary CIDR exists.

### 4e. Private DNS and private access
```bash
tests/test5-pod-networking.sh private            # see §3; saved to test5-private.txt
tests/test5-pod-networking.sh cleanup            # removes the netshoot pods and cb-capacity
```

### 4f. Back to default pod networking (optional; do it before destroy, or not at all)
```bash
tests/test5-pod-networking.sh restore
```
This prints the order: `aws/eks` with both toggles off first (the nodes roll back), then
`aws/spoke-app` without the secondary CIDR, once no ENIs are left in the pod subnets. It
deletes the ENIConfigs. If you are destroying everything at the end of the session anyway,
skip this.

---

## 5. Test 6: Kubernetes traffic control

Results go to `docs/runs/test6-*`.

### 5a. Part A: NetworkPolicy
```bash
tests/test6-traffic-control.sh policy
```
1. Starts `cb-probe` (netshoot, `app=probe`) in the `cloudbridge` namespace of both clusters.
2. Runs a 7-flow matrix in each cluster **before** the policies: everything is allowed.
3. Applies [`k8s/policies/aws`](../k8s/policies/aws) to EKS and
   [`k8s/policies/azure`](../k8s/policies/azure) to AKS. Both are standard NetworkPolicy:
   - `default-deny`: all ingress and egress in `cloudbridge`;
   - `allow-dns`: every pod → CoreDNS (`k8s-app=kube-dns`) on 53;
   - `frontend-egress-to-backend` + `backend-ingress-from-frontend`: TCP 8080;
   - `frontend-ingress-from-lb`: EKS from the ALB subnets `10.10.4.0/23`; AKS from
     `0.0.0.0/0` except `10.244.0.0/16` (the ILB is pass-through, so the real client IP
     arrives).
   - Optional, AKS only: `CILIUM_EXTRAS=1` also applies
     [`k8s/policies/cilium`](../k8s/policies/cilium), the same rule written with Cilium
     entities.
4. Runs the matrix **after**, with `cilium-dbg monitor --type drop` recording on the AKS node.
5. Collects the evidence:
   - **AKS:** Cilium drop events (`Policy denied`) and `hubble observe --verdict DROPPED`, if
     Hubble is enabled. Hubble needs Advanced Container Networking Services, which is paid.
   - **EKS:** the DENY lines from the VPC CNI network policy agent's flow log
     `/var/log/aws-routed-eni/network-policy-agent.log` on each node. The add-on has
     `enablePolicyEventLogs` on. A short-lived pod per node mounts the log read-only.
   - VPC flow logs will **not** show these drops: the security group accepted the packet, and
     the drop happens in eBPF on the node.

| Flow | After |
|---|---|
| frontend → backend:8080 | allowed |
| probe → backend:8080 | **blocked** |
| probe → CoreDNS | allowed |
| probe → internet 443 | **blocked** |
| backend → frontend:80 | **blocked** |
| frontend → internet 443 | **blocked** |
| internet → LB → frontend `/health` | allowed (ALB on EKS, firewall public IP on AKS) |

The policies stay applied. `tests/test6-traffic-control.sh policy-off` removes them.

### 5b. Part B: AKS egress through the hub firewall (changes the Azure firewall, restores itself)
```bash
tests/test6-traffic-control.sh egress-azure      # ~15 min
```
0. **Shows the egress IP** an AKS pod has on the internet: the firewall's public IP. It then
   copies `/etc/nftables.conf`, the live ruleset (`nft -s list ruleset`) and `/etc/dnsmasq.d`
   to `/var/lib/cloudbridge/egress-backup` on the firewall, only once.
1. **Baseline on the node**, via `az vmss run-command`, which goes through the VM agent and
   still works when egress is cut:
   - API server `/healthz`;
   - ACR `/v2/`;
   - `crictl pull` from MCR and from Docker Hub;
   - a non-allowlisted site;
   - `chronyc tracking` / `sources`;
   - kubelet errors.
2. **Block everything** from `10.20.0.0/20` to non-`10/8` destinations for `BLOCK_SECS`
   (default 120 s; keep it under 300 s, or the NotReady node starts evicting pods).
   - The script adds a `jump egress` rule right after the conntrack rules, with an `egress`
     chain that logs (`fw-egress-deny`) and drops.
   - It cuts the existing flows with `conntrack -D`.
   - **Expect:** the node goes **NotReady** after about 40–50 s (kubelet can't renew its lease
     through the firewall); every pull fails; the API is unreachable from the node; chrony
     loses `ntp.ubuntu.com`. The clock may stay in sync from the Hyper-V PTP source, so
     record what chrony shows.
3. **Allowlist:**
   - The `egress` chain accepts the nftables set `inet fw allow4`, UDP 123, and nothing else.
   - dnsmasq gets one `nftset=/…/4#inet#fw#allow4` line for Microsoft's required AKS FQDNs:
     `*.hcp.northcentralus.azmk8s.io`, `mcr.microsoft.com`, `*.data.mcr.microsoft.com`,
     `mcr-0001.mcr-msedge.net`, `management.azure.com`, `login.microsoftonline.com`,
     `packages.microsoft.com`, `acs-mirror.azureedge.net`, `packages.aks.azure.com` and
     `ntp.ubuntu.com`.
   - It also gets the ACR login server, plus `blob.core.windows.net`: ACR Basic has no
     dedicated data endpoint, so layers come from blob storage.
   - dnsmasq restarts with an empty cache and the main names are resolved once to seed the
     set. From then on, **every answer dnsmasq gives a node fills the set**: the allowlist
     follows DNS.
   - If the dnsmasq build has no nftset support, the script says so and falls back to the
     one-time resolution.
   - **Expect:**
     - the node is Ready again;
     - MCR and ACR pulls work;
     - a pod from ACR with `imagePullPolicy: Always` runs;
     - a Docker Hub pod goes `ErrImagePull`;
     - bing.com stays blocked;
     - the `fw-egress-deny` log shows what else the node tried to reach.
4. **Restore:** removes the jump, the chain, the set and the dnsmasq file, restarts dnsmasq,
   and compares the ruleset with the backup (`ruleset identical to the backup: RESTORED`).

### 5c. Part B: EKS egress through fw-a / fw-b (changes both AWS firewalls, restores itself)
```bash
tests/test6-traffic-control.sh egress-aws        # ~5 min
```
- Uses the same firewall script over SSM. On both firewalls, from `10.10.0.0/26`,
  `10.10.0.64/26` and `10.10.64.0/18` to the internet, it allows only **TCP 443** and
  **UDP 123** and drops and logs the rest.
- **Expect:**
  - **Blocked:** plain HTTP (80), ping, DNS to `1.1.1.1`, SSH to github.com:22.
  - **Still working:** `https://www.example.com`, and also `https://www.wikipedia.org` and
    any other site on 443. Also Docker Hub and ECR pulls, node status, and in-VPC DNS.
- **Why nothing in EKS breaks:** DNS goes to the VPC resolver, time to the Amazon Time Sync
  Service (169.254.169.123), and the API server is reached on its private endpoint. None of
  them crosses the firewall.
- **The point:** a port says nothing about the destination. Production uses AWS Network
  Firewall domain lists (TLS SNI / HTTP Host, with TLS inspection when SNI can't be trusted)
  or a proxy. It also uses VPC interface endpoints, so AWS API traffic never needs the
  internet path.

### 5d. Inbound: why AKS ingress is DNAT on the firewall
```bash
tests/test6-traffic-control.sh inbound-asym
```
- **The documented problem:** with a public LB on AKS and the UDR `0.0.0.0/0` → firewall, a
  user's SYN reaches the node through the LB and never touches the firewall. The node's
  SYN-ACK follows the UDR to the firewall, whose conntrack never saw the SYN. It is
  `ct state invalid` and gets dropped (and would be SNATed to the wrong public IP if it got
  through).
- **Demonstrating it** needs a 4th public IP, and the subscription allows 3. So this is a
  documented check of the working design instead:
  - tcpdump and conntrack start on the Azure firewall for your public IP;
  - you curl `http://<fw public IP>/health` 5 times;
  - the firewall shows all 4 legs (in, DNAT out to `10.20.4.10`, reply in, reply out), a
    conntrack entry with both directions and `[ASSURED]`, and the DNAT counters growing.

---

## 6. Destroy (end of session)

Delete the Kubernetes load balancers first. Otherwise the ALB, which the LB controller owns
and Terraform doesn't, keeps the app VPC's subnets in use.

```bash
tests/test6-traffic-control.sh policy-off; tests/test5-pod-networking.sh cleanup
kubectl --context cloudbridge-eks -n cloudbridge delete ingress frontend    # the controller deletes the ALB (1–2 min)
kubectl --context cloudbridge-aks -n cloudbridge delete svc frontend        # the internal LB
aws elbv2 describe-load-balancers --region us-east-2 --query 'LoadBalancers[].LoadBalancerName'   # wait for []
helm --kube-context cloudbridge-eks uninstall aws-load-balancer-controller -n kube-system
```

Then the clusters, then Session 1's order:
```
azure/aks ──┐
aws/eks ────┴── ops ── connectivity/vpn ──┬── azure/spoke-aks ── azure/hub
                                          └── aws/spoke-app ── aws/hub
```
```bash
cd terraform/azure/aks && terraform destroy          # terminal 1, ~10 min
cd terraform/aws/eks   && terraform destroy          # terminal 2, ~10 min (ECR has force_delete)
```
If `enable_secondary_cidr` / `enable_prefix_delegation` / `enable_custom_networking` were
passed with `-var`, pass the same flags to `destroy`. Otherwise the plan first tries to undo
them (harmless, just slower).

Then follow [Session 1 §4](session1-runbook.md#4-destroy-end-of-session-reverse-order) and
finish with `tests/inventory.sh` → `CLEAN: ...`. It also lists EKS clusters and load
balancers, so a leftover ALB shows up there.

---

## Session cost

These are approximate list prices, with both clusters up.

| Item | ≈ $/hr |
|---|---|
| Session 1 network (TGW × 4 attachments, 2 VPNs, VpnGw1AZ, firewalls, endpoints, IPs) | 0.55–0.70 |
| EKS control plane | 0.10 |
| EKS nodes, 2 × t3.medium Spot | 0.03 |
| ALB | 0.03 |
| AKS Free tier, 1 × B2als_v2 | 0.04 |
| ACR Basic, ECR storage | < 0.01 |
| Data through the firewall NAT and VPN (image pulls, tests) | < 0.05 |
| **Total** | **≈ $0.85–1.00/hr**, so ≈ $5 for a 5–6 h session |

The Session 1 test hosts are not needed in Session 2 (they would also take node-subnet IPs
that Test 5 counts).

---

## Notes and known limits found while writing the scripts

- **Firewall changes are live only.** Test 6 never edits `/etc/nftables.conf`. If a run is
  interrupted and the trap couldn't run (laptop asleep, lost login), re-run the same
  subcommand: every firewall step is idempotent and the restore runs at the end. Or reboot the
  firewall VM.
- **`az vmss run-command` and `az vm run-command`** each take 20–40 s and return only the last
  4 KB, so the remote scripts print summaries.
- **The FQDN allowlist only sees names resolved through the Azure firewall.** A node that
  connects to a cached IP, or uses a hard-coded IP, is blocked. That is the intended
  behaviour, but it explains a short burst of `fw-egress-deny` right after the switch.
- **AKS Cilium and `ipBlock`:** AKS documents that `ipBlock` can't select pod or node IPs. The
  AKS frontend rule only needs outside addresses, so this doesn't matter here.
- **Kubelet probes under default-deny:** both engines allow host → local pod traffic, so the
  app stays Ready. `policy` prints pod readiness after applying, so a problem shows at once.
