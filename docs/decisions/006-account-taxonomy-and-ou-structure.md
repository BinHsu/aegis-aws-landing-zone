# 006. Account Taxonomy and OU Structure

## Status
Accepted

## Context
The first structural decision in any AWS landing zone is the account taxonomy: how many accounts, what they are called, what boundaries they enforce, and how they are organized into OUs. This decision is load-bearing for everything that follows. SCPs attach at OU level and inherit to members. Cross-account networking topology depends on which accounts exist to route between. Blast radius is defined by account boundaries. Getting this wrong is possible to correct later, but requires moving accounts between OUs, which triggers SCP re-evaluation and audit-trail noise.

AWS provides a reference taxonomy in its Security Reference Architecture (SRA). Control Tower and Landing Zone Accelerator both build on SRA-aligned structures. This ADR adopts a simplified subset of AWS SRA appropriate for a six-account portfolio project, and documents the expansion path to full SRA.

## Decision

Six AWS accounts organized under a simplified AWS Security Reference Architecture OU structure.

**Account list:**

- `aegis-management` — Root of the Organization. Hosts only AWS Organizations, SCPs, AWS Identity Center, and Billing. No workloads, no state buckets, no CI runners. Enforced by the management account boundary in ADR-001.
- `aegis-security` — Security tooling account. Hosts GuardDuty, Security Hub, AWS Config aggregation and admin console. Has interactive operator access for incident investigation. Corresponds to the `Audit` account in Control Tower's default layout.
- `aegis-logarchive` — Centralized log archive. Hosts write-only S3 buckets for CloudTrail organization trail, AWS Config history, and VPC Flow Logs. IAM policies are tightly locked down — near-zero human access, append-only for services. Corresponds to the `Log Archive` account in Control Tower's default layout.
- `aegis-shared` — Shared services. Hosts the Terraform state bucket (see ADR-003), Account Factory for Terraform, the GitHub OIDC identity provider, centralized ECR, and future self-hosted CI runners. Part of the Infrastructure OU per AWS SRA.
- `aegis-staging` — Non-production workloads. Isolated from production at the account level.
- `aegis-prod` — Production workloads.

**OU structure:**

```
Root
├── OU: Security
│   ├── aegis-security
│   └── aegis-logarchive
├── OU: Infrastructure
│   └── aegis-shared
└── OU: Workloads
    ├── aegis-staging
    └── aegis-prod
```

The management account `aegis-management` sits at the Root level and does not belong to any OU.

Control Tower provisions `aegis-security` and `aegis-logarchive` automatically during landing zone enrollment — these are the `Audit` and `Log Archive` accounts in Control Tower terminology, renamed via the Control Tower customization flow. The other three (`aegis-shared`, `aegis-staging`, `aegis-prod`) are provisioned via Account Factory for Terraform after the Control Tower landing zone is established. See ADR-008 for the Control Tower versus Terraform split.

## Alternatives Considered

**Flat structure with no OUs.** Rejected. SCPs must attach to every account individually, scaling poorly. Adding a new account requires remembering to re-attach the full SCP set, which is error-prone and creates audit noise.

**Full AWS SRA with `Sandbox`, `PolicyStaging`, `Suspended`, `Exceptions`, and `Deployments` OUs.** Over-engineered for a six-account lab. The additional OUs serve needs that do not yet exist: a sandbox for experimentation, a staging area for new SCPs before attachment to workload OUs, a holding area for decommissioned accounts. The simplified structure is documented as a subset of the full SRA, with the expansion path as an explicit future item. When the project grows to warrant these OUs — or is forked by an organization that already needs them — the addition is additive, not a restructure.

**Combine `aegis-security` and `aegis-logarchive` into a single security account.** Rejected. Separation of duties requires that the account with interactive operators — running queries against GuardDuty and Security Hub — is distinct from the account holding the immutable log archive. The log archive is append-only cold storage with tight IAM policies precisely so that a compromise of the security account's interactive credentials cannot tamper with audit evidence. Control Tower enforces this split regardless by creating both accounts automatically during enrollment, so merging them would require disabling a Control Tower default.

**Skip `aegis-shared` and put Terraform state in `aegis-staging`.** Rejected. Shared services must not depend on workload account lifecycle. If `aegis-staging` is decommissioned or impaired, the state bucket must survive. A dedicated shared-services account is the standard AWS SRA answer.

**Per-team workload OUs (Workloads-AppA, Workloads-AppB, etc.).** Not applicable at current scale with a single operator. Recorded as a scaling direction: when multiple teams begin using the platform, workload OUs should be split by team or business unit to enable team-scoped SCPs.

## Consequences

SCPs attach at OU level. The region restriction SCP attaches once to the Root and inherits to every member account. Workload-specific SCPs attach once to the `Workloads` OU and inherit to both `aegis-staging` and `aegis-prod`.

New workload accounts are provisioned by Account Factory for Terraform pipeline runs, not console clicks. This enforces infrastructure-as-code discipline and creates an auditable history of account creation.

Control Tower owns the lifecycle of the Security OU accounts. Any change to `aegis-security` or `aegis-logarchive` beyond what Terraform can configure — for example, direct CloudTrail changes — must work within Control Tower's customization model rather than against it.

Expansion to full AWS SRA is additive. New OUs can be created without moving existing accounts. The Root-level SCPs remain unchanged; new OU-specific SCPs are simply added when each new OU is introduced. This makes the simplified structure a safe starting point rather than a dead end.
