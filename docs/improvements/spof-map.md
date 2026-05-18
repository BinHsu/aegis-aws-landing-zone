<!-- session-close-review: SPOF list reflects the account-fabric architecture; mitigation entry references still exist -->
# SPOF Map — Region-down and Account-down

This document inventories the single points of failure (SPOFs) in the current AWS account fabric and indicates which improvement entries address each. It is the structural map that [`README.md`](README.md) and individual entries reference.

> **Scope note.** Per [ADR-033](../decisions/033-landing-zone-scope-correction-account-fabric.md) this repository owns the **account fabric** only — there is no workload data plane here. The SPOFs below are governance- and state-backend SPOFs. Workload SPOFs (EKS clusters, ALBs, ECR, NAT Gateways) belong to the Platform tier in the separate `aegis-platform` repository.

## Two axes

Failure modes divide into two fundamentally different threat classes:

1. **Region-down**: an AWS region becomes unavailable (service outage, infrastructure incident). Historically resolves in hours; AWS does not publish SLAs that bound this duration. Mitigation: cross-region replication of the state backend.

2. **Account-down**: an AWS account becomes unusable (compromise, accidental closure, SCP self-lockout, credential takeover). Grace period is 90 days for accidental closure via AWS Support. Mitigation: cross-account separation, immutable audit trails, break-glass access.

These threat classes do not overlap. Cross-region replication does not protect against account compromise; cross-account replication does not protect against regional outages. A complete reliability posture requires both axes addressed.

## Region-down SPOFs

| SPOF | Impact in current account fabric (single-region) | Mitigation path |
|---|---|---|
| `eu-central-1` S3 (state bucket) | 🔴 `terraform apply` blocked across all layers; no running system affected | [001](001-state-backend-spof.md) — cross-region replica |
| `eu-central-1` KMS | 🔴 State decryption fails; `terraform apply` blocked | [001](001-state-backend-spof.md) — destination KMS in replica region |
| `eu-central-1` IPAM service | 🟡 CIDR allocation requests blocked; existing allocations unaffected | Not mitigated — IPAM is regional; pools can be re-created from Terraform in the DR region if needed |
| GitHub Actions regional outage | 🟡 CI unavailable; no running system affected | Not mitigated — GitHub SLA 99.9%, accepted |

**Key observation**: every region-down SPOF in the account fabric blocks the *deployment* path only. The account fabric provisions and governs — it does not serve traffic — so a region-down event here delays infrastructure changes; it does not cause an outage.

## Account-down SPOFs

These persist regardless of region. Cross-region operations still live within a single account.

| SPOF | Scenario | Impact | Mitigation path |
|---|---|---|---|
| `aegis-shared` compromised / closed | SCP bypass + destruction; accidental closure | State bucket + IPAM pools gone | [001](001-state-backend-spof.md) — cross-account replica to `aegis-logarchive` |
| `aegis-management` compromised | Org root takeover; OU reorganization disaster | Organization-wide governance lost | **004** (planned) — break-glass IAM role + offline root MFA |
| SCP self-lockout | A bad SCP change denies the role that applies SCPs | CI cannot deploy; human cannot SSO | **005** (planned) — manual override policy + root escape via management account (root is SCP-immune) |
| OIDC provider deletion | `aws_iam_openid_connect_provider` removed from an account | CI cannot authenticate to that account | Per-account OIDC providers (existing design limits blast radius to one account); the provider is a singleton owned by this repo and re-creatable from Terraform |
| SSO / IAM Identity Center compromise | Identity Center tenant attacked | No human console/CLI access | **004** (planned) — break-glass IAM role with hardware MFA, credentials stored offline |

**Key observation**: account-down SPOFs cannot be solved by more AWS infrastructure. They require *external* defenses — offline credentials, cross-account audit replication, explicit break-glass procedures, human operational discipline.

## How cross-region replication affects the SPOF map

If [`001`](001-state-backend-spof.md) is fully implemented:

- Region-down state-backend rows (S3, KMS) become 🟢 — `terraform apply` can re-point at the replica.
- Account-down rows remain unchanged — cross-region replication offers them no protection at all; entry 001's *cross-account* layer is what addresses `aegis-shared` loss.

This is why cross-region is necessary but not sufficient. Account-down threats require entries 001 (its cross-account layer), 004, and 005, which exist on a separate axis.

## Unmitigated and acknowledged risks

These are documented as residual risk rather than addressed in current improvement entries:

- **AWS service-wide or control-plane outage** (e.g., historical `us-east-1` IAM/STS incidents). No cross-region or cross-account mitigation exists for AWS's own control plane. Risk accepted.
- **GitHub outage**. No mirror of the source of truth. Lab operations pause until GitHub recovers. Risk accepted.
- **Signature root compromise**. If the operator's commit signing key is compromised, the attacker can push signed malicious commits to `main`. Mitigated by branch protection and required reviews, but a single-operator lab cannot two-person-review. Risk accepted at lab scale; production would require per-environment signing authorities and an independent review channel.

## Related ADRs and references

- [ADR-002 — Region and Availability Zone strategy](../decisions/002-region-and-availability-zone-strategy.md) — establishes `eu-central-1` + `eu-west-1` pair.
- [ADR-003 — Terraform backend bootstrap](../decisions/003-terraform-backend-bootstrap.md) — the state bucket architecture that entry 001 addresses.
- [ADR-006 — Account taxonomy and OU structure](../decisions/006-account-taxonomy-and-ou-structure.md) — the six-account structure that scopes account-down impact.
- [ADR-033 — Landing-zone descope to the account fabric](../decisions/033-landing-zone-scope-correction-account-fabric.md) — the scope boundary that defines which SPOFs this map covers.
