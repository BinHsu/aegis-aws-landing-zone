# 018. Multi-region EKS design

## Status
Accepted

## Context

The lab currently runs a single EKS cluster in `eu-central-1` per [ADR-013](013-eks-architecture.md). For [`docs/improvements/008-workload-multi-region.md`](../improvements/008-workload-multi-region.md) to describe a productionizable DR posture, the Terraform codebase has to support multi-region clusters as a first-class design rather than a retrofit.

Two constraints shape the design:

1. **Cost**. EKS control plane is $73/month per cluster. The lab cannot afford persistent multi-region DR. The design must make the region count a config knob rather than a code fork so that demo cost can be tuned per session.

2. **Terraform provider-alias limitation**. Provider aliases in Terraform must be declared statically — they cannot be generated at runtime from a list. This constrains the "any N regions" generality the design would otherwise claim.

Additional requirements carried forward from earlier design sessions:

- **Governance footprint** (IPAM, Control Tower, SCP coverage) is one decision; **workload compute footprint** (EKS clusters) is a separable decision. The latter must be a *subset* of the former but does not have to be identical.
- Any multi-region design must preserve the repo split ([ADR-007](007-infra-app-repository-split.md)): `aegis-core` stays region-agnostic, `aegis-aws-landing-zone` owns topology.
- DR target is **pilot light with pre-warmed capacity** (Mode A, no ECR replication). See Consequences for the explicit boundary.

## Decision

### 1. Two separate region lists in config

```yaml
regions:                     # Governance footprint — permanent infrastructure
  - name: eu-central-1
    role: primary
    zones: [...]
  - name: eu-west-1
    role: dr
    zones: [...]

eks:
  staging:
    regions:                 # EKS compute footprint — tuned per demo session
      - region: eu-central-1
        role: primary
        mode: active
```

- `regions[]` drives IPAM regional pools, Control Tower governed regions, SCP `deny-non-eu-regions` scope. Permanent, rarely changes.
- `eks.<env>.regions[]` drives how many EKS clusters exist. Ephemeral — expanded per demo, collapsed for normal sessions.

### 2. Four invariants, validated at two layers

1. Exactly one `role: primary` in top-level `regions[]`.
2. Exactly one `role: primary` in each `eks.<env>.regions[]`.
3. `eks.<env>.regions[].region` values must be a subset of `regions[].name`.
4. `eks.<env>.regions[].region` values must be unique within a list.

Validation layers:

- `scripts/validate-config.py` — pre-commit, earliest feedback.
- Terraform `check` blocks in each layer's `config.tf` — plan-time defense in depth.

JSON Schema cannot express invariants 2–4 (cross-field constraints are outside its grammar). Python + Terraform cover what schema cannot.

### 3. Terraform provider pattern: module with `configuration_aliases`

Per-cluster resources (EKS cluster, Karpenter IAM, LB Controller, ArgoCD, CoreDNS addon, access entries) are encapsulated in a sub-module. Each `eks.regions[]` entry gets its own module invocation with a per-region provider alias passed in.

```hcl
# staging/platform/providers.tf — STATIC aliases, required by Terraform
provider "aws" { alias = "eu_central_1" region = "eu-central-1" }
provider "aws" { alias = "eu_west_1"    region = "eu-west-1" }

# modules/eks-cluster/versions.tf
terraform {
  required_providers {
    aws = {
      configuration_aliases = [aws.cluster_region]
    }
  }
}

# staging/platform/main.tf
module "cluster_primary" {
  source    = "./modules/eks-cluster"
  providers = { aws.cluster_region = aws.eu_central_1 }
  region    = "eu-central-1"
  ...
}

module "cluster_slave_1" {
  count     = length(local.eks_regions) > 1 ? 1 : 0
  source    = "./modules/eks-cluster"
  providers = { aws.cluster_region = aws.eu_west_1 }
  region    = "eu-west-1"
  ...
}
```

**Scaling boundary**: the lab declares two static provider aliases (`eu_central_1`, `eu_west_1`). Adding a third region requires adding both a provider alias block in `providers.tf` and a module invocation in `main.tf`. This is a Terraform language limitation, not a design choice — see Alternatives D.

### 4. State structure: single state per layer

All `for_each(eks.regions)` resources live in the same state file as the rest of their layer. State key is unchanged (`staging/platform/terraform.tfstate`). Not per-region, not per-workspace.

Keeps plan coherent (one plan sees the whole layer), avoids HashiCorp-acknowledged workspace footguns, and does not embed region names into state paths.

### 5. Route 53 failover via health check

Route 53 hosted zone provisioned by ldz. Failover routing policy:

- Primary record points at primary cluster's ALB DNS.
- Secondary record points at slave cluster's ALB DNS.
- Health check monitors the primary ALB.
- Health check fails → Route 53 switches to secondary within ~60 seconds.

**Cost**: $0.50/month hosted zone + $0.50/month per health check + negligible DNS queries at lab scale.

**Demo capability**: enables the "kill primary cluster, observe automatic failover" scenario. Playbook to be formalized in `docs/runbooks/006-multi-region-failover-demo.md` after Session C verification.

### 6. DR mode: pilot light, no ECR replication (lab default)

When a slave region entry has `mode: pilot_light`:

- Minimum 1 replica per service pre-warmed (image cached on DR nodes at deploy time).
- No DaemonSet on DR except essential system components (CoreDNS, Karpenter running on Fargate).
- Manifests use primary region's ECR URL; DR cluster pulls cross-region in normal operation (first pull ~10–30 s, then cached; ~$0.02/GB one-time data transfer).
- **No ECR cross-region replication**. Replication alone — without paired ApplicationSet per-cluster image URL rewrite — provides no DR benefit during primary outage because manifest image URLs still reference the (unreachable) primary region. Replication + ApplicationSet is the Mode B upgrade path documented in [entry 008](../improvements/008-workload-multi-region.md).

### 7. ArgoCD topology: per-cluster, not central

Each EKS cluster gets its own ArgoCD Helm release. All ArgoCDs point at the same `aegis-core` repo path. No central controller managing remote clusters.

This avoids ArgoCD becoming a new SPOF. A central ArgoCD in the primary region would fail exactly when you need it most — during a primary region outage.

Trade-off: each cluster has its own admin password and requires operator access separately. Acceptable for a single-operator lab. Team-scale deployments with proper ArgoCD HA can revisit.

## Alternatives Considered

### A. Single flat config list — no separation between `regions[]` and `eks.regions`

Rejected. Coupling governance (IPAM, Control Tower, SCP coverage) to compute topology forces either "always multi-region everywhere" (wastes governance capacity on empty regions) or "always single-region everywhere" (no DR option). The subset relationship gives both axes independent knobs.

### B. Positional convention (`regions[0] = primary`) instead of explicit `role`

Rejected. Position-based convention breaks silently if someone alphabetizes or `yq`-formats the YAML — primary silently swaps regions without any loud signal. Explicit `role` field with schema enum plus a Terraform `check` for "exactly one primary" gives loud failure, which is strictly better than silent incorrectness.

### C. Workspace per region

Rejected. Terraform workspaces carry HashiCorp-acknowledged baggage (`default` workspace confusion, no environment isolation guarantee per [HashiCorp's guidance](https://developer.hashicorp.com/terraform/cli/workspaces)) and embed region names into state paths anyway. The `for_each` + single-state pattern is the modern Terraform idiom and doesn't commit forkers to workspace semantics.

### D. Dynamic provider aliases from a list

Not available. Terraform's language does not support runtime provider generation. OpenTofu 1.7+ has preliminary discussion but no stable feature as of 2026-04. The static alias declaration is unavoidable for this codebase's expected lifetime.

### E. Central ArgoCD managing remote clusters

Rejected for this design. Central ArgoCD becomes a new SPOF — if the primary-region ArgoCD goes down during the primary outage it is supposed to orchestrate, failover cannot happen. Per-cluster ArgoCD sidesteps this. Mature team deployments with proper ArgoCD HA can revisit.

### F. Active-active workload (both regions serve production traffic)

Out of scope. Active-active requires bidirectional stateful data replication (Aurora Global, DynamoDB Global Tables, etc.) and complicates session affinity and consistency. Cost also doubles the workload baseline. For lab tier, active-passive pilot light meets the RTO=1h / RPO=1h design target.

### G. ECR replication enabled by default in Mode A

Rejected. Replication alone — without ApplicationSet per-cluster image URL rewrite — provides only a latency benefit in normal operation; during primary outage, manifests still point at the unreachable primary ECR URL. Paying engineering effort for cosmetic infrastructure without paired rewrite is a portfolio anti-pattern. Documented as the Mode B upgrade path with the full stack (replication + ApplicationSet + core-side manifest parameterization) in [entry 008](../improvements/008-workload-multi-region.md).

## Consequences

### Easier

- Adding or removing a region is a config change: edit `eks.<env>.regions[]`, run `terraform apply`. Code does not change within the two-region static-alias envelope.
- Demo cost is explicitly tunable. A 1-region session runs at baseline; 2-region pilot light adds roughly $2 per 4-hour session.
- Governance and compute footprints are decoupled — IPAM can span N regions while EKS runs in fewer.

### Harder

- Top-level provider alias blocks must match supported regions. Adding a third region beyond `eu-central-1` + `eu-west-1` is a code change plus an ADR amendment, not a pure config change.
- ECR images in DR cluster pull cross-region from primary in normal operation (small data transfer cost + first-pull latency).

### DR limitation (explicit boundary)

Mode A (lab default) has a hard capacity ceiling during primary region outage:

- DR serves traffic only up to the **aggregate pre-warmed pod capacity** of its existing cached nodes.
- HPA and Karpenter scale-up during the outage **fails**. Reasons:
  - (a) Manifest `image:` fields reference primary region ECR URL.
  - (b) Primary region — including its ECR endpoint — is unreachable during the outage.
- New Karpenter nodes during outage get stuck on `ImagePullBackOff`.

This is a deliberate design choice for lab tier, not a bug. The Mode B upgrade path in [entry 008](../improvements/008-workload-multi-region.md) removes this limit at the cost of enabling ECR replication, introducing ApplicationSet-based per-cluster image URL rewrite, and coordinating one manifest-parameterization change in `aegis-core`.

The limitation is acceptable for the demo scenario ("kill primary, observe DNS failover, DR serves pre-warmed capacity for trivial demo load"). It would be unacceptable for real production traffic.

### Cross-repo impact: none for Mode A

`aegis-core` is unchanged by Mode A multi-region: same ECR push target, same manifest format, same root Application path. Scale comes from adding cluster instances (ldz side only). This preserves [ADR-007](007-infra-app-repository-split.md)'s repo split under multi-region.

Mode B does require one core-side change (parameterize image registry in manifests). That is documented in [entry 008](../improvements/008-workload-multi-region.md)'s upgrade section and gated on a coordinated `aegis-core` issue per the cross-repo rule in `CLAUDE.md`.

### Portfolio implication

The design demonstrates, in order of senior-engineering maturity:

1. **Governance vs compute footprint separation** — a distinction most teams collapse and later regret.
2. **Explicit invariants at multiple validation layers** — schema catches structural errors, Python catches cross-field constraints, Terraform catches plan-time drift.
3. **Honest boundary documentation** — the Mode A DR limitation is written directly into the ADR rather than hidden.
4. **Cost-as-lever mindset** — demo cost tunable by config; "pay what you want to prove" rather than one-size-fits-all infrastructure.
5. **Repo split preservation** — multi-region does not spread to the application repo; the split is structurally enforced.
