<!-- session-close-review: SPOF list reflects deployed architecture; mitigation entry references still exist -->
# SPOF Map — Region-down and Account-down

This document inventories the single points of failure (SPOFs) in the current lab architecture and indicates which improvement entries address each. It is the structural map that [`README.md`](README.md) and individual entries reference.

## Two axes

Failure modes divide into two fundamentally different threat classes:

1. **Region-down**: an AWS region becomes unavailable (service outage, infrastructure incident). Historically resolves in hours; AWS does not publish SLAs that bound this duration. Mitigation: multi-region architecture.

2. **Account-down**: an AWS account becomes unusable (compromise, accidental closure, SCP self-lockout, credential takeover). Grace period is 90 days for accidental closure via AWS Support. Mitigation: cross-account separation, immutable audit trails, break-glass access.

These threat classes do not overlap. Multi-region does not protect against account compromise; cross-account replication does not protect against regional outages. A complete reliability posture requires both axes addressed.

## Region-down SPOFs

| SPOF | Impact in current lab (single-region) | Mitigation path |
|---|---|---|
| `eu-central-1` EKS cluster outage | 🔴 Workload fully unavailable | [008](008-workload-multi-region.md) — pilot light in `eu-west-1` |
| `eu-central-1` S3 (state bucket) | 🔴 `terraform apply` blocked; running workloads unaffected | [001](001-state-backend-spof.md) — cross-region replica |
| `eu-central-1` KMS | 🔴 State decryption fails; running workloads unaffected | [001](001-state-backend-spof.md) — destination KMS in replica region |
| `eu-central-1` ECR | 🟡 New pod pulls fail; pods with cached images continue | [008](008-workload-multi-region.md) Mode B — cross-region replication |
| `eu-central-1` ALB | 🔴 Ingress down | [008](008-workload-multi-region.md) — Route 53 failover to DR ALB |
| `eu-central-1` NAT Gateway | 🟡 Outbound internet blocked for nodes in that AZ/region | Co-mitigated by 008 (DR VPC has its own NAT) |
| GitHub Actions regional outage | 🟡 CI unavailable; running workloads unaffected | Not mitigated — GitHub SLA 99.9%, accepted |

**Key observation**: most region-down SPOFs in the CI/deployment path do not affect running workloads. Deployment-pipeline availability and runtime availability are separate SLO dimensions and should not be collapsed.

## Account-down SPOFs

These persist regardless of multi-region. Cross-region operations still live within a single account.

| SPOF | Scenario | Impact | Mitigation path |
|---|---|---|---|
| `aegis-shared` compromised / closed | SCP bypass + destruction; accidental closure | State + IPAM gone | [001](001-state-backend-spof.md) — cross-account replica to `aegis-logarchive` |
| `aegis-management` compromised | Org root takeover; OU reorganization disaster | Organization-wide governance lost | **004** (planned) — break-glass IAM role + offline root MFA |
| `aegis-staging` compromised | Credential takeover; deliberate destruction | Workload data + ECR images gone | **004** (planned) — per-account SCP + logarchive CloudTrail forensics |
| SCP self-lockout | A bad SCP change denies the role that applies SCPs | CI cannot deploy; human cannot SSO | **005** (planned) — manual override policy + root escape via management account (root is SCP-immune) |
| OIDC provider deletion | `aws_iam_openid_connect_provider` removed from an account | CI cannot authenticate to that account | Per-account OIDC providers (existing design limits blast radius to one account) |
| SSO / IAM Identity Center compromise | Identity Center tenant attacked | No human console/CLI access | **004** (planned) — break-glass IAM role with hardware MFA, credentials stored offline |

**Key observation**: account-down SPOFs cannot be solved by more AWS infrastructure. They require *external* defenses — offline credentials, cross-account audit replication, explicit break-glass procedures, human operational discipline.

## How multi-region affects the SPOF map

If [`008`](008-workload-multi-region.md) is fully implemented (Tier 2+):

- Region-down workload row becomes 🟢.
- Region-down CI path rows remain 🔴 unless entry 001 is also implemented.
- Account-down rows remain unchanged — multi-region offers them no protection at all.

This is why multi-region is necessary but not sufficient. Account-down threats require entries 001, 004, and 005, which exist on a separate axis.

## Unmitigated and acknowledged risks

These are documented as residual risk rather than addressed in current improvement entries:

- **AWS service-wide or control-plane outage** (e.g., historical `us-east-1` IAM/STS incidents). No cross-region or cross-account mitigation exists for AWS's own control plane. Risk accepted.
- **GitHub outage**. No mirror of the source of truth. Lab operations pause until GitHub recovers. Risk accepted.
- **Signature root compromise**. If the operator's commit signing key is compromised, the attacker can push signed malicious commits to `main`. Mitigated by branch protection and required reviews, but a single-operator lab cannot two-person-review. Risk accepted at lab scale; production would require per-environment signing authorities and an independent review channel.

## Related ADRs and references

- [ADR-002 — Region and Availability Zone strategy](../decisions/002-region-and-availability-zone-strategy.md) — establishes `eu-central-1` + `eu-west-1` pair.
- [ADR-003 — Terraform backend bootstrap](../decisions/003-terraform-backend-bootstrap.md) — the state bucket architecture that entry 001 addresses.
- [ADR-006 — Account taxonomy and OU structure](../decisions/006-account-taxonomy-and-ou-structure.md) — the six-account structure that scopes account-down impact.
- [ADR-018 — Multi-region EKS design](../decisions/018-multi-region-eks-design.md) — the architectural spec that entry 008 implements.
