<!-- session-close-review: deprecation list and version tracking table §4 match the account-fabric layers and their actual versions -->
# Change Review Discipline

> **Scope**: account-fabric change review — SCP changes, IAM surfaces (roles, policies, trust relationships), the GitHub OIDC provider, AWS Organizations / Control Tower features, IPAM pool changes, GitHub Actions workflow edits, and Terraform provider / module bumps.
>
> **Not in scope**: workload Platform-tier changes (EKS, cluster add-ons, ArgoCD, observability, edge) and application-manifest changes. Per [ADR-033](../decisions/033-landing-zone-scope-correction-account-fabric.md) the Platform tier lives in the separate `aegis-platform` repository, and the application lives in [`aegis-core`](https://github.com/BinHsu/aegis-core); each carries its own change discipline.

This document is an **operational discipline doc**, not an ADR. It captures *how* account-fabric changes are reviewed on this repo — the mental checklist before a PR opens and the automated guardrails before it merges. ADRs record *what* was decided; this doc records *how to decide well*.

---

## 1. Why this matters more than usual for an account-fabric repo

An account-fabric change has two qualities most changes don't:

1. **Blast radius is org-wide.** A broken SCP takes effect across every account in the OU it is attached to; a broken IAM trust policy can lock the CI principal out of an account; an OIDC provider misconfiguration breaks authentication for every workflow in every consumer repo. The surface that *looks* like one file change is often the entry point to the whole organization.
2. **Deprecations arrive with long fuses.** AWS deprecates resource attributes across provider major bumps; GitHub Actions deprecates syntax silently via Node version changes; Control Tower retires guardrail identifiers. The time between "noticed" and "broken" is long enough that the fix stops feeling urgent — which is exactly when it becomes a production surprise.

Specific deprecations already on the horizon as of 2026:

- **AWS provider v5 → v6** (major bump) — handled 2026-04-15; baseline apply succeeded across all account-fabric Terraservices. See Incident 24 aftermath for the Dependabot rebase sequencing.
- **GitHub Actions `node20` → `node24`** — actions pinned in `.github/workflows/` must be checked for the Node runtime treadmill on every Dependabot bump.
- **AWS Organizations / Control Tower guardrail identifiers** — Control Tower occasionally renames or retires the managed guardrail IDs; verify against the current Control Tower console before relying on an identifier in code or docs.

If any of the above surprised a team, it's because their discipline wasn't continuous. The cost of the discipline is lower than the cost of the surprise.

---

## 2. The 5-step checklist (applies to every account-fabric PR)

Before merging a change — whether a Terraform diff or a workflow edit — the author (and reviewer) must answer all five. If any answer is "I don't know," the PR is not ready.

### 2.1 Blast radius
*If this change misbehaves, what is the smallest set of systems affected? The largest?*

- "Only this one IAM policy in one account" — low blast.
- "Every workflow run in every repo that authenticates via the OIDC provider" — high blast.
- "Every account in the org root OU" — highest blast (e.g., a new SCP at the root).

**Rule**: changes with account-wide or org-wide blast must include a rollback plan in the PR description, not just in the reviewer's head.

### 2.2 Dependency assumptions
*What is this change assuming about the state of other components?*

- "This SCP assumes it applies *after* the CI role exists, or it self-locks the applier" — caused real incidents (PR #8, PR #9); SCPs apply last for this reason.
- "This IAM policy assumes the GitHub OIDC provider was already registered" — subtle; the provider is a singleton owned by this repo and consumer repos `data`-lookup it.
- "This Terraform data source assumes the remote state file is reachable from this principal" — caused Incident 5 (cross-account `kms:Decrypt` on `aws/s3`).

**Rule**: list the non-obvious dependencies explicitly. "Obvious to me now" becomes "invisible in six months."

### 2.3 Deprecation status of what's being touched
*Is the API / resource / action version you're using still supported? For how long?*

- **Terraform provider attributes**: check the provider's upgrade guide (e.g., [AWS provider v6 upgrade guide](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/guides/version-6-upgrade)).
- **GitHub Actions**: the `node20` → `node24` deprecation is an ongoing treadmill. Check the action's repo for "uses Node.js 20" warnings in its README or latest release notes.
- **AWS service APIs**: check the service's deprecation notices (AWS generally deprecates with long fuses) — Organizations, Control Tower guardrail IDs, and SCP condition keys all warrant a check before a PR relies on them.

**Rule**: if the thing you're touching is deprecated, the PR must either (a) migrate to the replacement, or (b) explicitly justify staying on the deprecated path with an end-of-life date.

### 2.4 Rollback plan
*If this change breaks something we didn't catch in review, how do we revert? How long does revert take?*

- **Fastest**: `git revert` + CI apply. Viable when the change is a single commit and the state file is consistent with the code (most account-fabric changes are this shape).
- **Medium**: revert the commit, then run a narrower apply (e.g., `terraform apply -target=...`). Needed when partial application has left state + AWS diverged.
- **Slowest**: manual state surgery — `terraform state rm` + re-import — needed for stuck state locks or orphaned resources. For SCP self-lockout the rollback is a root-credential escape via the management account (root is SCP-immune); see [`break-glass-apply.md`](break-glass-apply.md).

**Rule**: "we'll figure it out" is not a rollback plan. Put the command line in the PR description.

### 2.5 2 AM readability
*If the on-call (including future-me) is debugging this at 2 AM, will the code make sense?*

- Variable names descriptive enough to re-parse in a coffee-deprived brain?
- Comments where the *why* is non-obvious and not captured elsewhere?
- Resource names following the repo-scoped naming convention so they do not collide with sibling repos' resources in the same AWS account? (See `CLAUDE.md` naming discipline — bare `aegis-` prefixes collided twice with a sibling repo.)
- ADR reference in the PR description for the decision this change embodies?

**Rule**: the code you ship is the code someone else will read under stress. Optimize for that reader.

---

## 3. Automated deprecation detection

Human checklists degrade. Automate the detections that cost nothing to run.

### 3.1 Terraform provider upgrade diffing

When a Dependabot PR bumps a provider across a major version boundary (v5 → v6), the `Terraform Plan` PR comment is the artifact. Expected signals:

- **No resource changes** in plan output → clean major bump (AWS provider v6 on 2026-04-15 had this shape across all account-fabric Terraservices).
- **Resource changes** in plan output → read each change carefully against the provider's upgrade guide. Likely renames / default changes, not bugs.
- **Plan errors** → the provider's stricter validation in the new major version caught an existing misconfiguration. Fix the config, don't pin to the old provider.

### 3.2 Checkov IaC security scan

`checkov.yml` runs on every PR. It catches misconfigured security posture — public S3, unencrypted resources, over-broad IAM — before merge. A drifted security setting blocks the PR; this is the shift-left guardrail for the account fabric's IAM/KMS/S3 surface.

### 3.3 GitHub Actions runtime treadmill

Pinned actions in `.github/workflows/` carry a Node runtime that AWS and GitHub deprecate on a rolling basis (`node20` → `node24`). On every Dependabot action bump, check the action's release notes for runtime-version warnings rather than merging blind.

### 3.4 CloudTrail / Config as a deprecation observatory

The org CloudTrail trail and AWS Config feed `aegis-logarchive`. Deprecated-API usage by any principal in the org surfaces in CloudTrail; AWS Config rule evaluations flag drift from the recorded baseline. Today these are collected but not alerted on — a documented improvement, not an implemented one.

---

## 4. Account-fabric version tracking

The living inventory of what's deployed and when it expires. Maintained in this document as a lightweight alternative to a CMDB.

> **Update rule**: whenever an account-fabric component version changes (Terraform apply merged to main, a provider bumped, a Control Tower landing-zone version upgraded), update this table in the same PR. Out-of-date version tracking is worse than no tracking.

| Component | Version | Upstream EOL / deprecation | Our migration trigger | ADR |
|---|---|---|---|---|
| Terraform CLI | 1.14.8 | — | — | [ADR-003](../decisions/003-terraform-backend-bootstrap.md) |
| AWS provider | 6.x (all account-fabric layers) | v6 EOL TBD | Dependabot PR when v7 releases | — |
| AWS Control Tower landing zone | Current (AWS-managed) | AWS-managed; periodic landing-zone version bumps | Apply the landing-zone update when AWS publishes a new version | [ADR-008](../decisions/008-landing-zone-tooling-control-tower-hybrid.md) |
| AFT (committed, not deployed) | Version-pinned, CI-validated | tracks the AFT module releases | Activated only if Path B is chosen | [ADR-011](../decisions/011-account-provisioning-two-path-strategy.md) |

> **Workload Platform-tier components** (EKS, Karpenter, ArgoCD, observability charts, cert-manager, etc.) were tracked in this table before the [ADR-033](../decisions/033-landing-zone-scope-correction-account-fabric.md) descope. They now live in the `aegis-platform` repository and are tracked there.

---

## 5. How this connects to existing discipline

- [**ADR-005 — ISO 27001 Annex A.8 Change Management**](../decisions/005-compliance-framework-iso-27001.md): the formal framework this doc is the *executable form* of. ADR-005 says "we do change management." This doc says "here is the checklist, here are the tools."
- [**ADR-008 — Control Tower hybrid**](../decisions/008-landing-zone-tooling-control-tower-hybrid.md): tooling choices that pre-emptively reduce deprecation risk by staying on managed surfaces (Control Tower instead of hand-rolled Organizations wiring) where the cost-benefit favors them.
- [**ADR-033 — Landing-zone descope to the account fabric**](../decisions/033-landing-zone-scope-correction-account-fabric.md): the scope boundary that defines what "account-fabric change" means in this doc.
- [**CLAUDE.md**](../../CLAUDE.md): the operational rules that live at the project root. This doc defers to CLAUDE.md on anything it restates.

---

## 6. Boundary: what this document does NOT cover

- **Workload Platform-tier changes**: EKS, cluster add-ons, ArgoCD, observability, edge — these moved to the `aegis-platform` repository per [ADR-033](../decisions/033-landing-zone-scope-correction-account-fabric.md) and carry their own change discipline there.
- **Application code changes**: see [`aegis-core`'s change discipline](https://github.com/BinHsu/aegis-core) when that repo documents its own.
- **Hot-fixing production directly**: this repo has no production workloads. The break-glass *apply* path for the account fabric is governed by [`break-glass-apply.md`](break-glass-apply.md).
- **Dependency pinning strategy**: covered by Dependabot config (`.github/dependabot.yml`). This doc is about reviewing what Dependabot proposes, not about whether Dependabot should propose it.
- **Incident response**: see [`docs/incidents.md`](../incidents.md) and the per-incident postmortems. This doc is preventive; incidents are post-hoc.

---

*Last updated: 2026-05-18 — recast for the account-fabric scope per [ADR-033](../decisions/033-landing-zone-scope-correction-account-fabric.md): Kubernetes / cluster-component references and the Platform-tier version-tracking rows were removed; the checklist, deprecation list, and automated-detection section now cover SCPs, IAM surfaces, the OIDC provider, Organizations / Control Tower, and IPAM. Originally written 2026-04-15; Incident 24 (Terraform state-lock stampede under Dependabot bulk rebase) remains the first case study exercising step 2.4 (rollback plan) and 3.1 (provider upgrade diffing).*
