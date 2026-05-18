<!-- session-close-review: index table + statuses match the actual ADR files; reading orders still point at ADRs that exist -->

# Architecture Decision Records

This directory holds the Architecture Decision Records (ADRs) for the AWS
landing zone. An ADR captures a significant design choice — account placement,
tooling, security posture — at the moment it was made, together with the
alternatives that were rejected and the trade-offs accepted.

**Conventions**

- **Numbering**: sequential, zero-padded (`001`, `002`, …). Never reused.
- **Filename**: `NNN-title.md`.
- **Status**: `Accepted` | `Superseded by NNN` | `Deprecated`. A superseded ADR
  is *not* deleted — it stays as a historical record; only its `Status` line
  changes. Amendments are annotated inline at the top of the affected ADR.
- **Relocation exception**: an ADR whose *entire subject* moved to another
  repository — as happened in the ADR-033 account-fabric descope, when EKS,
  ArgoCD, observability, edge, auth and FIS were reclassified as a Platform
  tier — is *removed* from this directory rather than kept as a tombstone. The
  `v1.0.0` git tag preserves the full pre-descope ADR set; the
  [Relocated ADRs](#relocated-adrs--adr-033-descope) note below records which
  numbers moved and why. This differs from supersession (same repo, decision
  changed) — relocation means the decision is no longer *this repo's* to own.
- **Rule**: AI agents and contributors must check this directory before
  proposing architecture. If a decision is already recorded, follow it; if you
  believe it should change, discuss first — do not silently override.

Low-contention choices (a default that nobody argued about) do **not** get an
ADR — they live in code comments or in `CLAUDE.md`. An ADR is for decisions
where alternatives were genuinely weighed.

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [001](001-landing-zone-scope-boundary.md) | Landing Zone Scope Boundary | Accepted (amended by 033) |
| [002](002-region-and-availability-zone-strategy.md) | Region and Availability Zone Strategy | Accepted |
| [003](003-terraform-backend-bootstrap.md) | Terraform Backend Bootstrap and State Layout | Accepted |
| [004](004-deployment-configuration-contract.md) | Deployment Configuration Contract | Accepted |
| [005](005-compliance-framework-iso-27001.md) | Compliance Framework — ISO 27001 Mapping | Accepted |
| [006](006-account-taxonomy-and-ou-structure.md) | Account Taxonomy and OU Structure | Accepted |
| [007](007-infra-app-repository-split.md) | Infrastructure / Application Repository Split | Accepted (amended by 033) |
| [008](008-landing-zone-tooling-control-tower-hybrid.md) | Landing Zone Tooling — Control Tower + Terraform Hybrid | Accepted |
| [009](009-lifecycle-and-teardown-strategy.md) | Lifecycle and Teardown Strategy | Accepted (amended by 033) |
| [010](010-shared-account-bootstrap-sequence.md) | Shared Account Bootstrap Sequence | Accepted |
| [011](011-account-provisioning-two-path-strategy.md) | Account Provisioning Strategy — Two-Path Design | Accepted |
| [012](012-ipam-and-cidr-allocation.md) | IPAM and Org-Wide CIDR Allocation | Accepted (amended; was "VPC Topology and Egress Strategy") |
| [024](024-landing-zone-repo-topology.md) | Landing-zone Terraform Repo Topology | Accepted (amended by 033) |
| [029](029-iam-permission-scope-down.md) | IAM Permission Scope-Down for `github-actions-terraform` | Accepted (amended by 033) |
| [030](030-tier-2b-permission-boundary-hardening.md) | Tier 2B Permission Boundary Hardening | Accepted |
| [031](031-tier-3-detective-controls.md) | Tier 3 Detective Controls | Accepted |
| [033](033-landing-zone-scope-correction-account-fabric.md) | Landing-zone Scope Correction — Account Fabric | Accepted (supersedes 001 scope-list) |

> Filenames in the table are the conventional `NNN-title.md` form. If a link
> 404s, the on-disk title slug differs slightly — the number is authoritative.

## Relocated ADRs — ADR-033 descope

ADRs **013–023, 025–028, and 032** are intentionally absent. They recorded
**Platform-tier** decisions — EKS architecture, ALB session affinity,
observability tooling and backend, admission control, workload namespace/RBAC,
multi-region EKS and its external-orchestration successor, frontend serving,
FIS DR drills, Cognito auth, and the Qdrant vector-DB backend. ADR-033
reclassified all of that as an extractable Platform tier; the ADRs were
removed from this repo with the layers they governed. The **`v1.0.0` git tag**
is the historical record — `git show v1.0.0:docs/decisions/013-eks-architecture.md`
and so on. ADR numbers are never reused, so the gaps are permanent and
intentional.

## Reading orders by audience

You do not need to read every ADR front to back. Pick the path for why you are
here. Each list is ordered so the argument builds on itself.

### Senior platform / infrastructure reviewer

Understand the shape of the account fabric and why it is shaped that way.

`001` → `033` → `006` → `008` → `011` → `003` → `004` → `024` → `007` → `002` → `012`

Scope boundary first — read `001` immediately with `033`, which corrects that
scope down to the account fabric and reclassifies EKS/ArgoCD/observability as
an extractable Platform tier. Then the account/OU taxonomy, the
Control-Tower-plus-Terraform tooling split, and how accounts are provisioned.
State layout and the config contract explain how the code is parameterised;
the repo-topology and infra/app-split ADRs explain the tier model. `002` and
`012` close it out: the region strategy and the org-wide IPAM that the fabric
hands to Platform-tier consumers.

### Reliability / recovery reviewer

Understand the failure model of the control plane itself.

`002` → `009` → `003`

Region/AZ strategy and the lifecycle/teardown model set the baseline; the
state-backend ADR explains recovery of the Terraform control plane — the one
piece of durable state the account fabric owns.

### Security reviewer

Understand the guardrails and the blast-radius controls.

`001` → `005` → `006` → `008` → `029` → `030` → `031` → `011`

Scope and the ISO 27001 mapping frame the compliance intent; account taxonomy
and tooling show where SCP guardrails sit. `029`–`031` are the IAM scope-down
ladder (permission scope-down → permission boundary → detective controls).
`011` covers account provisioning.

### Forker / new contributor

The minimum to understand the repo before touching anything.

`001` → `033` → `004` → `024` → `008` → `009`

What the repo is for and how its scope was corrected (`033` descopes it to the
account fabric), how config drives it, how the one repo is isolated
internally, what tooling it assumes, and the lifecycle/teardown rules that keep
a fork from running up a bill.
