# 027. Intra-environment Terraservice layer sharding discipline

## Status

Accepted (2026-04-24).

## Context

[ADR-024](024-landing-zone-repo-topology.md) answers the **repo-level** topology question: why a single landing-zone repository instead of per-account repos. Its trigger list for revisiting — team boundaries, CODEOWNERS, audit tiering, PR velocity, blast-radius incidents — is organizational.

A separate, finer-grained question arises **within one environment**:

> "You have `staging/edge/` carrying a CloudFront frontend cert (us-east-1 ACM), an ALB api cert (regional ACM), a delegated Route53 zone, and a GitHub OIDC role. Shouldn't those be separate Terraservice layers?"

The organizational triggers from ADR-024 do not apply here — all four surfaces share the same operator, same approval gate, same CI matrix entry, same state backend pattern. The question is **technical**: when does a Terraservice layer inside one environment need to shard.

The immediate case that prompted this ADR: PR #108 (2026-04-20) added the gateway ALB's ACM cert + DNS validation to the existing `staging/edge/` layer, silently merging rather than forking a new `staging/edge-api/`. The decision was correct but undocumented. Future readers — forkers, interviewers, and a future version of this operator — deserve the reasoning explicitly, plus a decision framework for the next instance.

## Decision

**Keep `staging/edge/` as a single Terraservice layer.** Do not shard on cert pattern, hostname count, or provider alias count. Revisit only when one of four **technical** triggers fires.

### Four triggers that force an intra-environment shard

1. **Apply cadence divergence.** If two resource groups inside one layer develop independent apply rhythms — e.g., a customer-tenant LB set that applies weekly while the gateway applies quarterly — the slower group's `plan` time starts blocking the faster group's iteration. State lock contention between humans or CI runs becomes measurable. Shard by cadence.

2. **Permission boundary change.** If a new consumer requires cross-account ACM import, customer-held KMS keys, or any IAM surface that does not cleanly extend the current layer's role, the boundary is the signal. This is an identity problem, not a resource-count problem; a new layer gets a new OIDC role with a narrower scope.

3. **New provider family.** Introducing Shield Advanced, WAF v2 at org scope, Global Accelerator, or any Terraform provider that does not co-exist with the current provider set without aliasing contortions. The slot pattern from [ADR-018](018-multi-region-eks-design.md) §3 handles regional aliases of the *same* provider cleanly; it does not handle fundamentally new provider kinds.

4. **Zone ownership migration.** If the Route53 hosted zone moves — parent-domain migration, multi-zone split for prod vs staging, tenant-owned zones — the zone itself graduates to a standalone `staging/dns/` (or similar) layer, and `edge/` becomes a `terraform_remote_state` consumer. This is the highest-cost shard; plan carefully.

### Not triggers

- **Number of ALBs, CloudFront distributions, or ACM certs.** `for_each` on a hostname set or map absorbs N consumers linearly, in the same layer, with no state migration. Growing from 1 to 10 ALBs does not require a shard.
- **"Feels complex now."** Without a measurable threshold (apply wall-clock time, resource count, state-read chain depth), the urge to split is premature abstraction — exactly what CLAUDE.md's *"three similar lines is better than a premature abstraction"* rule warns against.

### Implementation discipline: defer parameterization until the second consumer arrives

Today `staging/edge/acm-api.tf` uses a scalar `local.api_hostname`. Do **not** pre-parameterize to `for_each = toset(local.api_hostnames)` in anticipation of future hostnames. When the second gateway-shape hostname actually arrives, that PR does the refactor:

```hcl
# config.tf
locals {
  api_hostnames = {
    gateway = "aegis-api.staging.${local.config.domain.name}"
    admin   = "aegis-admin.staging.${local.config.domain.name}"
  }
}

# acm-api.tf
resource "aws_acm_certificate" "api" {
  for_each    = local.api_hostnames
  domain_name = each.value
  # ...
}

# outputs.tf — scalar becomes map
output "api_acm_certificate_arns" {
  value = { for k, v in aws_acm_certificate_validation.api : k => v.certificate_arn }
}
```

The refactor is ~15 minutes; the cost of living with a scalar until then is zero. Same spirit as ADR-018 §3's slot pattern — the repo commits to a concrete shape today and grows when the need is real, not anticipated.

## Alternatives Considered

### A. Standalone `staging/edge-api/` layer

Rejected. Would require moving the Route53 hosted zone to its own layer (otherwise `edge/` and `edge-api/` both want to own it), converting one side to a `terraform_remote_state` consumer, writing an ADR for the zone-ownership split, and running a state migration + cold-apply validation. All for zero current benefit: the four triggers above are not fired.

Also unresolved: the GitHub OIDC role for aegis-core frontend lives in `edge/` today. Splitting api out forks the "OIDC role placement" question with no principled answer — the frontend role could stay in `edge/` (asymmetric) or move to a new `staging/iam-aegis-core/` (yet another layer). The cascade of follow-on splits is the signal that the first split is premature.

### B. Extend ADR-024 with a new § "Layer-within-environment sharding"

Rejected. ADR-024 is *Status: Accepted* (2026-04-21) and scoped to **repo boundaries**. Expanding its scope after acceptance conflates organizational triggers (team ownership, CODEOWNERS) with technical triggers (apply cadence, provider family) — future readers would have to sort them. A separate ADR with a § Related cross-link preserves the audit trail and matches the project's "one decision per ADR" norm.

## Consequences

### Makes easier

- "Why didn't you split `edge/` into `edge-api/`?" — a one-paragraph answer backed by four documented triggers, not gut feel.
- A forker's own edge layer has a clear sharding rule; they are not forced to adopt the project's current merged shape or invent their own framework.
- `for_each` deferral is explicit; reviewers can cite this ADR to reject premature parameterization on future PRs.

### Makes harder

- The 27th ADR is one more file in the index; onboarding cost is marginally higher.
- "Apply cadence divergence" and "feels complex now" share a fuzzy boundary — the ADR deliberately does not hardcode a threshold in minutes or PR counts, leaving judgment to the operator. This is a feature, not a bug; a hard threshold would be arbitrary. The four trigger shapes are specific enough that a false positive is obvious under review.

## Related

- [ADR-019](019-frontend-serving-strategy.md) — introduced `staging/edge/` as a dedicated Terraservice. This ADR explains why it stays merged rather than further subdivided.
- [ADR-024](024-landing-zone-repo-topology.md) — sibling framework at a coarser granularity. ADR-024 governs repo boundaries; ADR-027 governs Terraservice-layer boundaries within one environment. Both share the "logical isolation sufficient until specific signals fire" philosophy.
- [ADR-018](018-multi-region-eks-design.md) §3 — slot pattern for provider aliases. ADR-027's `for_each` deferral has the same "resist premature abstraction, grow when the need is real" spirit.
- [CLAUDE.md](../../CLAUDE.md) Technical Standards §Terraform — the "three similar lines is better than a premature abstraction" rule that backstops the deferral discipline.
