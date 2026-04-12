# 011. Account Provisioning Strategy — Two-Path Design

## Status
Accepted

## Context
After breaking the bootstrap cycle by manually creating `aegis-shared` (ADR-010), the project needs a strategy for provisioning the remaining accounts (`aegis-staging`, `aegis-prod`, and any future accounts). Two viable mechanisms exist: manual provisioning via Control Tower Account Factory console, and automated provisioning via Account Factory for Terraform (AFT). Each has different cost, complexity, and scaling characteristics.

A binary choice — "use AFT" or "don't use AFT" — creates a maintenance trap. If AFT is chosen and deployed, the $10-15/month ongoing infrastructure cost consumes a third of the project's $30/month budget ceiling for a capability that provisions accounts perhaps twice in the project's lifetime. If AFT is rejected outright, the repository loses the automation demonstration that matters at scale and the code rots without maintenance.

This ADR resolves the tension by treating account creation and account configuration as separate concerns, supporting both provisioning paths in the repository, and providing a decision tree for operators to choose at deployment time.

## Decision

The repository supports two provisioning paths. Both converge on the same Terraform bootstrap layer for account configuration.

```
Account Creation (choose one)          Account Configuration (invariant)
┌─────────────────────────┐
│ Path A: Manual AF       │──┐
│ (Console, zero cost)    │  │     ┌──────────────────────────────┐
└─────────────────────────┘  ├────▶│ terraform/environments/      │
┌─────────────────────────┐  │     │   <account>/bootstrap/       │
│ Path B: AFT             │──┘     │ Same code, same config YAML  │
│ (Pipeline, ~$10-15/mo)  │        └──────────────────────────────┘
└─────────────────────────┘
```

**Path A — Manual Account Factory (default for this project).**
Create accounts via Control Tower Account Factory in the AWS console. Follow the same procedure documented in Runbook 001 Part 8 for each account. After creation, record the account ID in `config/landing-zone.yaml`, add an SSO profile, assign the `PlatformAdmin` permission set, and run `terraform apply` against the account's bootstrap layer. Total cost: zero. Operator time per account: approximately 30 minutes including provisioning wait.

**Path B — Account Factory for Terraform (AFT).**
Deploy the AFT infrastructure from `terraform/environments/shared/aft/` into `aegis-shared`. AFT creates a CodePipeline-based automation stack that provisions accounts from Terraform definitions in a dedicated account-request repository. After deployment, new accounts are created by committing an account request file and merging. Total cost: approximately $10-15/month ongoing (CodePipeline, CodeBuild, Lambda, DynamoDB, S3). Operator time per account: approximately 5 minutes (write Terraform, merge PR).

**The bootstrap layer is the invariant.** Regardless of which path created the account, `terraform/environments/<account>/bootstrap/` runs the same Terraform code against it. The bootstrap layer reads account IDs from `config/landing-zone.yaml` and applies the account baseline: IAM account alias, OIDC providers, budget alarms, and any account-specific resources. This separation ensures that the repository does not have two divergent configuration paths — only the account creation mechanism differs.

**Decision tree for operators:**

| Condition | Recommended Path |
|-----------|-----------------|
| Fewer than 15 accounts, single operator | Path A (manual) |
| Budget under $20/month baseline | Path A (manual) |
| Multiple operators or teams requesting accounts | Path B (AFT) |
| Compliance requires pipeline audit trail for account creation | Path B (AFT) |
| More than 15 accounts projected | Path B (AFT) |

This project currently operates under Path A (6 accounts, single operator, $30/month budget).

**Keeping Path B alive.**
The AFT Terraform code at `terraform/environments/shared/aft/` is committed, version-pinned, and validated in CI. Phase 2 GitHub Actions runs `terraform validate` against all environments including `shared/aft/`, ensuring the code does not silently rot. When an operator decides to activate Path B, the code is deployable — not a stale placeholder.

## Alternatives Considered

**Deploy AFT now, use it for staging and prod.** Rejected for this project's current parameters. AFT's ongoing cost ($10-15/month) consumes 33-50% of the monthly budget for a capability used twice. The automation value does not justify the cost at six accounts with a single operator. However, the AFT code is written and maintained in the repository precisely so this alternative can be activated when conditions change.

**Only support Path A, no AFT code in the repository.** Rejected. This makes the repository a dead end at scale. When the project grows beyond 15 accounts or gains multiple operators, the absence of AFT code means starting from scratch. Writing and maintaining the AFT code now — at near-zero ongoing cost since it is not deployed — preserves the scaling path.

**Use AWS Organizations API directly (Terraform `aws_organizations_account`).** Rejected. Creating accounts via raw Organizations API bypasses Control Tower's baseline guardrails, Config recorder enrollment, CloudTrail integration, and SCP inheritance. Both Path A and Path B go through Control Tower's Account Factory mechanism, which applies the full baseline automatically.

## Consequences

The repository contains Terraform code that is maintained but not deployed (`shared/aft/`). This is analogous to a disaster recovery runbook: it exists, it is tested, but it is not active. Operators must understand that `shared/aft/` is intentionally not applied in the default deployment.

CI validation of `shared/aft/` catches syntax errors and module schema changes but cannot catch runtime errors (IAM permissions, resource limits, API changes). When an operator activates Path B, the first deployment may require debugging that `terraform validate` did not surface. This is documented in the runbook.

Path A requires manual steps for each new account (console clicks, config file updates, SSO assignment, permission set association). For six accounts this is approximately three hours of total operator time across the project lifetime. At 15+ accounts the manual overhead becomes untenable, which is the natural trigger for switching to Path B.

The bootstrap layer's role as the invariant simplifies testing. Any change to account baseline configuration is tested once and applied to all accounts, regardless of how they were created. This is the architectural property that makes two provisioning paths sustainable rather than burdensome.
