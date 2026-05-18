# 013. Landing-zone Terraform Repo Topology

## Status

Accepted (2026-04-21)

## Context

A recurring architectural question for landing-zone engineering:

> "This works for the lab, but when you actually go to production, shouldn't you split the Terraform into separate repositories per AWS account?"

The implicit premise — that "production maturity" requires repo-per-account — is widespread but **incorrect as a general claim**. Splitting repos is a reaction to specific organizational and operational constraints, not a milestone triggered by scale or production posture.

This ADR records:

1. Why the lab's single-repo layout (`terraform/environments/<purpose>/<layer>/`) is also the defensible production answer until specific signals appear.
2. What the "isolation" actually is (it is not at repo level).
3. Which concrete signals would trigger a split, and which direction to split in first.

This is partly an interview-prep artifact (the question comes up reliably) and partly a decision framework for a future operator weighing whether to split.

## Decision

**Maintain a single landing-zone repository** (`aegis-aws-landing-zone`) with per-account Terraform under `terraform/environments/<purpose>/<layer>/`. Achieve isolation at the **state, IAM, CI, approval-gate, and GitOps-workflow** levels — not at the repo level. Revisit only when one of the documented trigger signals (§ Consequences) fires.

### Isolation mechanisms in use (repo-split-independent)

| Mechanism | Purpose | Where it lives |
|---|---|---|
| **State isolation** | One state file per layer per account | [ADR-003](003-terraform-backend-bootstrap.md); `backend.tf` templated per directory |
| **IAM isolation** | GitHub OIDC role with account-scoped trust policy; no CI role touches multiple accounts | `terraform/environments/*/bootstrap/oidc-github.tf`; trust policy scoped by repo + ref + account |
| **Apply-workflow split** | Plan on PR; baseline auto-apply on merge to main | `terraform-plan.yml` vs `terraform-apply-baseline.yml` |
| **Plan-job matrix** | Every PR plans every layer that changed; layers are independent matrix targets | `.github/workflows/terraform-plan.yml` |
| **GitOps / CI-only apply** | Local `terraform apply` is break-glass only; normal apply path is merge to main | `docs/principles/break-glass-apply.md` + CLAUDE.md |

### Why GitOps-only apply changes the risk calculus

The single most common argument for repo-splitting is the "hand-slip apply" scenario — an operator intending `terraform apply` in one account accidentally targets another because the working directory is shared, a state file is mis-pointed, or a `-target` flag typos to the wrong resource. Repo split supposedly prevents this by requiring `cd ../other-repo/` before applying.

This repository eliminates the hand-slip structurally via GitOps discipline, not via directory separation:

- `terraform apply` happens ONLY through `terraform-apply-baseline.yml` (GitHub Actions, on merge to `main`).
- The workflow authenticates via GitHub OIDC, which issues a role scoped to a **single AWS account per workflow run** (trust policy conditions on repo + ref + account).
- Pull requests run `terraform-plan.yml` only — a read-only plan, never an apply; the plan-tier OIDC role cannot mutate anything.
- Local `terraform apply` is break-glass only and incident-tracked (see `docs/principles/break-glass-apply.md`). A local apply requires: (a) AWS SSO login to the specific account's role, (b) working-directory navigation to the specific layer, (c) a `plan` review, (d) an `apply` that is explicitly NOT the normal path. Each step is logged; the session itself becomes an incident entry.

Structural outcome: an operator CANNOT accidentally apply Terraform to the wrong account under normal operation because the normal apply path is workflow-only and the workflow is account-scoped by OIDC. A hand-slip would require multiple deliberate break-glass steps, each of which is logged and rare.

**This is the single strongest argument against repo-splitting at this scale**: the blast-radius containment comes from the apply mechanism, not the directory layout. A repo split without GitOps discipline is weaker than a monorepo with GitOps discipline.

## Alternatives Considered

### A. Split by account (`aegis-landing-zone-management`, `aegis-landing-zone-staging`, ...)

Rejected until team ownership demands it. Concrete cost: (1) cross-account atomic changes (e.g., SCP change in management + bucket policy change in security) become multi-PR coordinated releases; (2) shared modules need per-repo vendoring or a separate modules repo with semver discipline; (3) `gh issue list`, CODEOWNERS, tooling, CI configs duplicated per repo; (4) `terraform_remote_state` data sources cross repo boundaries and become versioning hazards.

The appropriate signal is **team boundary hardening** (e.g., a security team asserts sole ownership of the security-account Terraform), not "production readiness."

### B. Modules + live split (Gruntwork pattern: two repos)

`infrastructure-modules/` (reusable modules) + `infrastructure-live/` (account instances). Rejected for this repository because the modules surface is small (SCPs, IPAM, the per-account bootstrap baseline) and changes frequently with instances. Module versioning discipline (pinning, semver) becomes overhead without matching velocity benefit at this scale.

If a single repo split is the right first move (before per-account), **this is the recommended direction** — see "First split direction when triggered" in Consequences.

### C. Split by risk tier (baseline + workloads)

`landing-zone-management/` (management, security, logarchive) + `landing-zone-shared/` (shared, staging, prod bootstrap). Rejected because the same operator owns both groups, and the CI + state isolation already separates apply cadence appropriately. A compliance auditor demanding **separate audit trail per group** would reopen this — but no such auditor exists for this project.

### D. Split by environment (`aegis-infra-dev` + `aegis-infra-prod`)

Rejected at current scale. Would become reconsiderable if a stronger wall between management-account change authorship and workload-account iteration is needed. For now, account-scoped OIDC and per-layer state isolation do the same job at lower cost.

### E. Split by team (`@aws/security-owned`, `@aws/platform-owned`)

Rejected until team count >1. The lab is single-operator; this pattern is structurally unavailable.

## Consequences

### Isolation assurance — not mechanical at filesystem level, but not weak

Single-repo isolation is **logical** (via state, IAM, CI matrix, GitOps workflow) rather than **mechanical** (via filesystem separation across repos). A reviewer who never examines the CI config could plausibly believe a PR touches prod — but the CI will reject the apply if the role-to-account mapping is wrong, and the workflow cannot be triggered against an unexpected account.

For an auditor demanding **structural assurance** ("show me that this PR cannot possibly affect prod, regardless of CI state"), logical isolation does not satisfy. Repo-split provides that structural guarantee at the cost of cross-account refactor friction.

### Triggers to revisit this decision

Move toward split (direction depends on trigger):

1. **Team boundaries harden**. e.g., a security team insists on sole `management/scps/` ownership, rejects platform-team PRs → split toward **per-account** or **per-team**.
2. **Compliance requirement**. e.g., an auditor mandates separate change audit trail per risk tier → split toward **risk-tier** (baseline vs workloads).
3. **CODEOWNERS unmanageable**. The `.github/CODEOWNERS` file has >10 scope rules covering different directories with different reviewers → consider **per-team** split.
4. **Velocity data**. Sustained >50 PRs/week with >30% main-branch conflict rate → consider **modules + live** or **per-account** split to reduce PR interleaving.
5. **Blast-radius incident**. A PR to a non-prod layer inadvertently affected prod (e.g., SCP change scoped wrong, or a break-glass apply with an unintended target) → post-incident review may recommend structural guarantee.

**First split direction when a trigger fires**: modules + live (option B). Lower cost than per-account, provides ~80% of the isolation benefit, keeps governance in one place. Documented here to prevent whiplash later.

### Portfolio / interview utility

When asked "why not split Terraform by account?", the answer has structure:

> "Repo split is a response to specific organizational signals, not a production-maturity step. This repo uses logical isolation via state files, account-scoped IAM via GitHub OIDC, a CI matrix per layer, and GitOps-only apply — giving the blast-radius containment most people assume repo-splits provide. The 'hand-slip apply to the wrong account' risk that motivates splitting is eliminated by the apply mechanism being workflow-only, not by directory separation. I'd split when one of five signals fires: team ownership hardens, compliance mandates tier separation, CODEOWNERS melts down, velocity crosses ~50 PRs/week with >30% conflict rate, or I shipped a blast-radius incident. Until then, monorepo overhead is zero and cross-account refactors are one PR."

This is a staff / principal-level answer. The senior version collapses to "we do what Control Tower LZA does." The staff version names the triggers and identifies GitOps as the risk-calculus inverter.

### What this ADR does NOT close

- **Modules repo vs live repo** split (Gruntwork pattern, option B above) remains a live future option. If this ADR's signals 3 or 4 fire, option B is the recommended first split.
- **Tier boundaries** — orthogonal. [ADR-007](007-infra-app-repository-split.md) covers the Landing Zone / Platform / App tier model; this ADR is strictly about the Landing Zone tier's internal topology.

## Related

- [ADR-003](003-terraform-backend-bootstrap.md) — per-layer state isolation; the mechanism that makes single-repo safe
- [ADR-007](007-infra-app-repository-split.md) — the Landing Zone / Platform / App tier model (orthogonal to this ADR; the tier boundaries are chosen, an internal repo split is declined)
- [ADR-009](009-lifecycle-and-teardown-strategy.md) — teardown patterns that rely on layer boundaries inside the repo
- `docs/principles/break-glass-apply.md` — the exception-tracking mechanism that lets GitOps-only discipline hold under pressure
- [CLAUDE.md](../../CLAUDE.md) Technical Standards §Terraform — the operational conventions this ADR depends on
