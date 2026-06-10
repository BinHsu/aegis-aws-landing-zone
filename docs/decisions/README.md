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
  changes.
- **Rule**: AI agents and contributors must check this directory before
  proposing architecture. If a decision is already recorded, follow it; if you
  believe it should change, discuss first — do not silently override.

Low-contention choices (a default that nobody argued about) do **not** get an
ADR — they live in code comments or in `CLAUDE.md`. An ADR is for decisions
where alternatives were genuinely weighed.

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [001](001-landing-zone-scope-boundary.md) | Landing Zone Scope Boundary | Accepted |
| [002](002-region-and-availability-zone-strategy.md) | Region and Availability Zone Strategy | Accepted |
| [003](003-terraform-backend-bootstrap.md) | Terraform Backend Bootstrap and State Layout | Accepted |
| [004](004-deployment-configuration-contract.md) | Deployment Configuration Contract | Accepted |
| [005](005-compliance-framework-iso-27001.md) | Compliance Framework — ISO 27001 Mapping | Accepted |
| [006](006-account-taxonomy-and-ou-structure.md) | Account Taxonomy and OU Structure | Accepted |
| [007](007-infra-app-repository-split.md) | Infrastructure / Application Repository Split | Accepted |
| [008](008-landing-zone-tooling-control-tower-hybrid.md) | Landing Zone Tooling — Control Tower + Terraform Hybrid | Accepted |
| [009](009-lifecycle-and-teardown-strategy.md) | Lifecycle and Teardown Strategy | Accepted |
| [010](010-shared-account-bootstrap-sequence.md) | Shared Account Bootstrap Sequence | Accepted |
| [011](011-account-provisioning-two-path-strategy.md) | Account Provisioning Strategy — Two-Path Design | Accepted |
| [012](012-ipam-and-cidr-allocation.md) | IPAM and Org-Wide CIDR Allocation | Accepted |
| [013](013-landing-zone-repo-topology.md) | Landing-zone Terraform Repo Topology | Accepted |
| [014](014-iam-permission-scope-down.md) | CI OIDC Role Scope-Down | Accepted |
| [015](015-permission-boundary-hardening.md) | IAM Permission-Boundary Hardening | Accepted |
| [016](016-detective-controls.md) | Detective Control — Alert on Failed OIDC Assumption | Accepted |
| [017](017-platform-tier-extraction.md) | Platform Tier Extracted from the Landing Zone | Accepted |
| [019](019-budgets-iac-and-oidc-fail-closed.md) | Budgets Are IaC and the OIDC Trust Fails Closed | Accepted |

## Reading orders by audience

You do not need to read all 17 ADRs front to back. Pick the path for why you
are here. Each list is ordered so the argument builds on itself.

### Senior platform / infrastructure reviewer

Understand the shape of the account fabric and why it is shaped that way.

`001` → `006` → `008` → `011` → `010` → `003` → `004` → `013` → `007` → `017` → `002` → `012`

Scope boundary first, then the account/OU taxonomy, the
Control-Tower-plus-Terraform tooling split, and how accounts are provisioned
and bootstrapped. State layout and the config contract explain how the code is
parameterised; the repo-topology and tier-model ADRs explain how the repository
is isolated internally and where it sits in the Landing Zone / Platform / App
model. `017` records that the Platform tier was actually extracted to its own
repo, narrowing this fabric to account-fabric-only. `002` and `012` close it
out: the region strategy and the org-wide IPAM that the fabric hands to
Platform-tier consumers.

### Reliability / recovery reviewer

Understand the failure model of the control plane itself.

`002` → `009` → `003`

Region/AZ strategy and the lifecycle/destroy model set the baseline; the
state-backend ADR explains recovery of the Terraform control plane — the one
piece of durable state the account fabric owns.

### Security reviewer

Understand the guardrails and the blast-radius controls.

`001` → `005` → `006` → `008` → `014` → `015` → `016` → `019` → `011`

Scope and the ISO 27001 mapping frame the compliance intent; account taxonomy
and tooling show where the SCP guardrails sit. `014`–`016` are the CI security
ladder (OIDC role scope-down → SCP permission-boundary inner wall → detective
control on failed OIDC assumption); `019` closes the ladder's fail-open gap
(required `infra_repo_id`) and moves the cost guardrails into Terraform.
`011` covers account provisioning.

### Forker / new contributor

The minimum to understand the repo before touching anything.

`001` → `004` → `013` → `008` → `009`

What the repo is for, how config drives it, how the one repo is isolated
internally, what tooling it assumes, and the lifecycle/destroy rules that keep
a fork from running up a bill.
