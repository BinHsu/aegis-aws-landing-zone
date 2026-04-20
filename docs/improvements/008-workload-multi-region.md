<!-- session-close-review: multi-region status (IPAM ready, schema ready, Terraform pending, Mode A/B implementation state) still accurate -->
# 008. Workload multi-region DR

## Current state

| Layer | Multi-region ready | Actual deployment |
|---|---|---|
| IPAM CIDR allocation | ✅ Both `eu-central-1` and `eu-west-1` regional pools provisioned and RAM-shared | From inception |
| Config schema (`eks.<env>.regions[]` list + invariants) | ✅ Shipped in Session A | Session A (this PR) |
| Terraform modules (`staging/network`, `staging/platform`) — `for_each(eks.regions)` refactor | ✅ Shipped in Session B (2026-04-19) | PRs [#84](https://github.com/BinHsu/aegis-aws-landing-zone/pull/84) + [#92](https://github.com/BinHsu/aegis-aws-landing-zone/pull/92) |
| Terraform module (`staging/workloads`) — slot-pattern refactor (per-cluster GuardDuty + IRSA + namespace + Kyverno + observability) | ✅ Shipped in Session B (2026-04-20) | PR #(pending) |
| CI plan matrix for length-1 and length-2 | ✅ Shipped in Session B (2026-04-19) — workloads NOT in matrix (same as platform: needs upstream remote_state populated) | PR [#97](https://github.com/BinHsu/aegis-aws-landing-zone/pull/97) |
| K=2 slot ceiling hard guard (schema + `terraform_data.assert_k2_max`) | ✅ Shipped in Session B — guard now in 3 layers (network + platform + workloads) | PRs [#93](https://github.com/BinHsu/aegis-aws-landing-zone/pull/93) + #(pending) |
| Deployed workload clusters | 1 (primary only) | Default; forker opts into more via `eks.<env>.regions` list |
| Route 53 failover configuration | ❌ Not yet provisioned | Session B or C |
| ECR cross-region replication | ❌ By design — Mode A default | Mode B upgrade path below |

Architectural spec: [`docs/decisions/018-multi-region-eks-design.md`](../decisions/018-multi-region-eks-design.md).

## Gap / risk (lab default, single region)

| Failure mode | Impact | Duration |
|---|---|---|
| `eu-central-1` region outage | Workload fully unavailable | AWS-dependent (historically hours-to-days) |
| `eu-central-1` EKS control plane outage | New deploys blocked; running pods continue | AWS-dependent |
| AZ failure within `eu-central-1` | ✅ Already mitigated | <5 min automatic (multi-AZ) |

## Threat addressed

AWS region-level outage only. Account-down threats are handled in entries 001 and (planned) 004.

## RTO / RPO target

**Design target** (if multi-region is enabled): RPO=1h, RTO=1h for the workload layer.

**Meets target by** (Mode A, pilot light, lab default):

- DR cluster pre-warmed with minimum 1 replica per workload service.
- Route 53 health check + failover routing (~60-second DNS switch).
- Capacity ceiling = pre-warmed pod count + existing node capacity.

**Does NOT meet target for**:

- Burst traffic exceeding pre-warmed capacity during the outage.
- Any autoscaling scenario during the outage (see DR limitation in ADR-018 Consequences).

## Scope

**Workload data plane only** (user-facing availability). CI path SLO is [entry 001](001-state-backend-spof.md)'s concern.

## SLO impact

| Path | Before (single-region) | After (Mode A pilot light, 2-region) |
|---|---|---|
| Workload data plane | ~3 nines (single-region multi-AZ, limited by S3 region 99.9% SLA) | 3.5 nines (RTO=1h bounded, capped by pre-warmed capacity) |

## Mode A: pilot light — lab default

When `eks.<env>.regions` has length 1:

- 1 cluster @ primary region. HPA and Karpenter scale as normal.
- No DR infrastructure provisioned.
- Route 53 has a single primary record (no failover policy).
- Cost: baseline EKS cost (~$0.30/hour while running).

When `eks.<env>.regions` expands to length 2 with slave `mode: pilot_light`:

- 2 clusters, each with its own ArgoCD + Karpenter. Both point at the same `aegis-core` repo.
- Slave cluster has minimum 1 replica per service (image cached on slave nodes at deploy time).
- Route 53 health check provisioned; failover routing sends traffic to slave if primary ALB goes unhealthy.
- ECR replication **NOT** enabled — manifest image URL remains the primary region's ECR.
- Cost during a 4-hour session: ~$2 increment over single-region baseline.

### DR behavior (Mode A)

- Primary region down → Route 53 DNS switches to DR within ~60 s.
- DR serves traffic up to the aggregate pre-warmed pod capacity.
- HPA scale-up during outage **fails**: new pods cannot pull from primary ECR (same region going down).
- Karpenter's new nodes during outage get stuck on `ImagePullBackOff`.
- Outcome: DR absorbs steady-state and moderate burst; extreme bursts exceed capacity and return 503 until primary recovers.

This is acceptable for demo scenarios. Unacceptable for real production traffic at meaningful load.

## Mode B: warm standby with ECR replication — production upgrade path

Required to remove the Mode A scale-up limit during primary outage. Documented here as the roadmap, not the lab default.

### Steps (estimated ~2–3 hours ldz side + cross-repo coordination)

1. **ldz**: add `aws_ecr_replication_configuration` to `terraform/environments/staging/bootstrap/ecr.tf`. Replicate the `aegis-core` repo from primary region to each slave region's ECR. Replication cost at lab scale: ~$0.50/month.

2. **ldz**: convert `staging/platform/argocd.tf` root Application into an ApplicationSet with a list generator enumerating clusters. Inject a per-cluster `kustomize.images` patch that rewrites the image URL from primary ECR URL to the local-region ECR URL.

3. **core**: parameterize image registry in manifests. Two common patterns:
   - Helm: `.Values.image.registry` tunable; ApplicationSet injects per-cluster value.
   - Kustomize: base image uses primary URL; overlay per cluster rewrites via `images:` transformer.

   Verify at implementation whether `aegis-core`'s existing Kustomize structure already supports this — if so, core-side change is near-zero.

4. **Cross-repo coordination**: open an issue on the `aegis-core` standing cross-repo thread (#11) with the spec. Wait for `aegis-core`-side acknowledgment before landing the ldz PR. Per `CLAUDE.md`'s cross-repo rule, do not implement a cross-repo request before the other side's issue arrives.

### Mode A vs Mode B under failure

| Scenario | Mode A (pilot light) | Mode B (warm standby w/ replication) |
|---|---|---|
| Primary up, normal operation | Identical | Identical (DR pulls from local replica ECR) |
| Primary down, steady-state demand | ✅ DR serves with pre-warmed pods | ✅ DR serves |
| Primary down, HPA scale-up | 🔴 Scale fails (cannot pull image) | ✅ DR scales from local replica ECR |
| Primary down, new Karpenter node | 🔴 Stuck on `ImagePullBackOff` | ✅ New node pulls from local replica ECR |

### Why Mode A is default, not Mode B

- Mode A delivers the DNS-failover demo at trivial cost and zero cross-repo coupling.
- Mode B's ECR replication alone, without paired ApplicationSet rewrite, provides no meaningful DR benefit (see [ADR-018 Alternatives G](../decisions/018-multi-region-eks-design.md#g-ecr-replication-enabled-by-default-in-mode-a)).
- Mode B requires one coordinated `aegis-core` change, which is a cross-repo-blocking item and not appropriate to spend out ahead of actual need.

## Demo playbook (Mode A, Session C verification)

To be formalized in `docs/runbooks/006-multi-region-failover-demo.md` after Session C. Sketch:

```
1. Apply multi-region config: eks.staging.regions = [primary, slave]
   → ~6 min for both clusters to reach Ready
2. curl aegis-demo.example.com → response from primary cluster (hostname echo)
3. Simulate primary failure: kubectl -n workload scale deployment/core --replicas=0
   → primary ALB target becomes Unhealthy
4. Wait ~60 s for Route 53 health check to detect failure
5. curl aegis-demo.example.com → response now from DR cluster
6. Restore: kubectl -n workload scale deployment/core --replicas=3
7. curl aegis-demo.example.com → back to primary after health check re-passes
8. Teardown multi-region config (eks.staging.regions = [primary])
```

## Alternatives Considered

### A. Active-active (both regions serve production traffic)

Rejected for lab scope. 2× compute baseline plus bidirectional stateful data replication (Aurora Global, DynamoDB Global Tables) plus session-affinity complexity. Pilot light meets RTO=1h at roughly 30% of the cost.

### B. Cold restore (no DR infrastructure pre-provisioned)

Rejected. EKS cluster creation alone is 15–30 minutes. End-to-end from cold via Terraform (including Karpenter, Helm releases, ArgoCD bootstrap, CRD propagation) is 45+ minutes. Does not meet 1h RTO.

### C. Config feature flag `multi_region_enabled: true`

Rejected in favor of the list-driven design in ADR-018. A feature flag creates two separate code paths; only one is exercised in CI. The list approach uses the same `for_each` code regardless of list length — length-1 validates the same code path as length-N.

### D. ECR replication enabled by default in Mode A

Rejected. Replication without paired ApplicationSet per-cluster image URL rewrite provides no meaningful DR benefit during primary outage, because manifests still reference the unreachable primary ECR URL. Paying engineering effort for infrastructure that looks like DR but does not function as DR is a portfolio anti-pattern.

### E. Image registry as a regional DNS alias resolved at pull time

Not available. AWS does not support ECR regional DNS aliasing for private registries. ECR pull-through cache is for external registries only (Docker Hub, GHCR, etc.), not for ECR-to-ECR caching.

## Prerequisites

1. **[ADR-018](../decisions/018-multi-region-eks-design.md) ratified.** ✅ (Session A.)
2. **Config schema has `eks.<env>.regions` list** with enum-constrained `role` and `mode`. ✅ (Session A.)
3. **Validation invariants in place** (exactly-one-primary, subset, uniqueness). ✅ (Session A.)
4. **Entry 001 implemented before Mode B ships.** A multi-region workload on a single-account state backend is asymmetric HA — workloads can survive region outages, but the deployment pipeline still collapses on any account-level event to `aegis-shared`. Mode B without 001 is architecturally inconsistent.

## Reversibility

| Component | Reversibility |
|---|---|
| DR region EKS cluster | Fully reversible (`terraform destroy`) |
| DR region VPC, NAT, ALB | Fully reversible |
| ECR cross-region replication rule (Mode B) | Fully reversible |
| Route 53 failover routing | Fully reversible |
| Per-region KMS keys | Reversible with 30-day deletion window |

All fully reversible at all layers. Lab can open and close multi-region per session.

## Cost estimate

### Mode A (lab default — pilot light, per 4-hour session with 2 regions)

| Component | Cost |
|---|---|
| Additional EKS control plane @ `eu-west-1` | ~$0.30 × 4h = $1.20 |
| Minimal Karpenter nodes (1–2 × t3.small) | ~$0.05/hour × 4h = $0.20 |
| NAT Gateway in DR VPC | ~$0.05 × 4h = $0.20 |
| Route 53 (prorated per session) | ~$0.005 |
| **Total session increment** | **~$2 per 4h session** |

### Mode B upgrade (persistent, if productionized)

| Component | Monthly |
|---|---|
| ECR replication storage | ~$0.05 |
| ECR cross-region data transfer | ~$0.40 |
| Route 53 health check | ~$0.50 |
| **Total persistent increment** | **~$1/month** |

Mode B requires ~2–3 hours of ldz engineering + a cross-repo `aegis-core` change.

## Operational burden (when multi-region is running)

| Task | Cadence | Time |
|---|---|---|
| K8s version sync across clusters | Per EKS version bump | 2–4 hours |
| ArgoCD per-cluster admin management | Ongoing | ~1 hour/month |
| Manifest consistency verification | Monthly | 1 hour |
| DR drill (failover exercise) | Quarterly | 4 hours |
| Cost monitoring | Weekly | 10 minutes |
| **Total when multi-region active** | | **~6–8 hours / month + upgrade spikes** |

Because the lab's policy is "EKS layer open/close per session" rather than persistent, this burden is only paid during active multi-region sessions, not continuously.

## Validation plan

1. **At Session B completion**: `terraform plan` passes cleanly for both `eks.<env>.regions` length-1 and length-2 configurations in CI.
2. **At Session C (first end-to-end apply)**: apply with length-2, verify DR cluster reaches Ready, ArgoCD sync succeeds, cross-region pull latency < 60 s for a test workload. Teardown completes cleanly with no orphan resources.
3. **Demo drill**: run the demo playbook end-to-end and confirm failover-to-DR completes within 90 seconds.
4. **Retrospective**: any cold-apply incidents get captured in `docs/incidents.md` (consistent with prior cold-apply discipline from Incidents 10–20).

## Portfolio angle

1. **Governance vs compute footprint separation** — `regions[]` (permanent governance) vs `eks.<env>.regions[]` (tunable compute) as separate concerns. Senior architectural distinction most teams collapse.
2. **List-driven Terraform idiom** — `for_each` exercises the same code regardless of list length; no dead-code paths.
3. **Explicit DR limitation documented** — the Mode A "pilot light cannot scale during outage" constraint lives inline, not hidden. Honest operational maturity.
4. **Cost-as-lever** — demo cost is config-tunable. "Pay per demo what you want to prove" rather than a one-size-fits-all cost baseline.
5. **Repo split preserved** — Mode A adds zero `aegis-core` changes; Mode B requires one minimal, coordinated change (standard manifest parameterization, not multi-region-specific). The split is structurally enforced.

## Compliance / residency

Both `eu-central-1` and `eu-west-1` are EU regions and satisfy [ADR-002](../decisions/002-region-and-availability-zone-strategy.md) + GDPR constraints.

## Lab status

**Partially implemented** (as of Session B 2026-04-20):

- ✅ IPAM multi-region (both regional pools, RAM-shared).
- ✅ Config schema `eks.<env>.regions` list (Session A).
- ✅ Validation invariants (Session A — Python + schema).
- ✅ Terraform `for_each(eks.regions)` refactor — **Session B done 2026-04-19** (network, platform sub-module, K=2 slot guard in 2 layers, CI plan matrix length-1 + length-2).
- ✅ Workloads layer slot-pattern refactor — **Session B closed 2026-04-20** (per-cluster GuardDuty + IRSA + namespace + NetworkPolicies + Kyverno + observability via `modules/eks-workloads`; K=2 guard now in 3 layers; ADR-015 + ADR-018 amended). Cross-repo coordination issue filed on aegis-core for the discovery contract.
- ⚠️ End-to-end verification apply + teardown (Session C — pending).
- ❌ Mode B (ECR replication + ApplicationSet + `aegis-core` coordination) — upgrade path documented, not a lab target.

Each demo session chooses 1-region (default, cheap) or 2-region (richer demo, ~$2–4 increment per 4h with workloads doubled).
