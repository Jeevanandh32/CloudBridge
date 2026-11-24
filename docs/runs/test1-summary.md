# Test 1: DNS with no single point of failure (Session 3, 2026-11-23)

**Setup:**
- **Domain:** `jeevs.click` is delegated at the registrar to **2 Route 53 + 2 Azure DNS** name
  servers. The .click TLD NS TTL is 900 s; delegation was confirmed on every TLD server.
- **Route 53:** answers `app.jeevs.click` with failover records (primary = ALB alias,
  secondary = the Azure firewall IP), backed by health checks.
- **Azure DNS:** answers with a CNAME to a **Traffic Manager** priority profile (ALB first, the
  Azure firewall second; `/health` every 10 s, 3 failures, TTL 30).

**Resolver under test:** unbound on AWS fw-a (internet through its own IGW, independent of
Azure), iterator only, all caches flushed before each query. "Route 53 unreachable" means every
Route 53 name-server IPv4 address is dropped on fw-a's OUTPUT with nftables.

## Part 1: real resolvers already use both providers

Before anything was broken, public resolvers split between the providers on their own:
- **Azure DNS:** 1.1.1.1, 8.8.8.8 and OpenDNS got the CNAME to Traffic Manager.
- **Route 53:** 9.9.9.9 got the plain A record.
- **Same result:** both answers pointed to the healthy AWS side.

## Part 2: Route 53 unreachable (provider loss)

| Step | Lookups ok | Median | p90 | Answered by |
|---|---|---|---|---|
| Normal | 20/20 | 120 ms | 271 ms | Route 53 15, Azure DNS 5 |
| **Route 53 blocked, cold resolver** | **20/20** | 263 ms (**+142 ms**) | 327 ms | **Azure DNS 20** |
| Route 53 blocked, resolver already knows it's down | 20/20 | 244 ms (+124 ms) | 300 ms | Azure DNS 20 |

MindBridge AI predicted about **3 s per lookup** (one full resolver timeout); the measured cost
was about **+140 ms**. unbound uses adaptive retransmit timeouts (about 376 ms here) and
switches provider quickly. The model now uses the measured value.

## Part 3: failover with Route 53 unreachable

Route 53 stayed blocked throughout (967 packets dropped). The AWS frontend was scaled to 0,
then restored.

| Measure | Result |
|---|---|
| Lookups answered | **304/304 by Azure DNS**, median 260 ms |
| AWS `/health` first failed | break + 2.2 s |
| **Answers point at Azure, and HTTP returns `"cloud":"azure"`** | **break + 36.4 s** |
| Failed polls during the outage | 17 of 120 |
| **Back on AWS after restore** | **restore + 14.5 s, 0 failed polls** |

- **Route 53's checkers agreed,** even though this resolver couldn't reach Route 53: 0/16
  healthy for AWS during the outage, and 16/16 after the restore.
- **Faster than v1.** v1 app loss through Route 53 alone took 77–107 s. Traffic
  Manager probes every 10 s and answers with a 30 s TTL; the Route 53 alias inherits 60 s.

## Findings

- **No single point of failure in DNS.** With Route 53 completely unreachable, every lookup
  still worked and failover still happened, decided by Traffic Manager's health checks.
- **A remaining dependency: the ALB's own name is served by Route 53.** In a *total* Route 53
  outage, a healthy AWS side still couldn't be resolved, so both providers would effectively
  fail users over to Azure. The test script's `BLOCK_ELB=1` mode reproduces this; it was not
  run this session.
- **Traffic Manager can't mix target types.** A profile rejects a mix of IPv4 and DNS-name
  external endpoints. The Azure firewall IP was given a DNS label
  (`*.northcentralus.cloudapp.azure.com`), so both endpoints are names.
- **The registrar resource defaults are unsafe.** `auto_renew` and `transfer_lock` both default
  to true in the provider, so both are set explicitly to false.
- **Delegation must be restored by hand after destroy.** Destroy doesn't reset the name servers.
  `~/cloudbridge-restore-ns.sh` puts the 4 Route 53 servers back at the registrar and in the
  zone apex NS.

Raw data: `test1-check.txt`, `test1-provider-loss.*`, `test1-failover-no-r53.*`.
