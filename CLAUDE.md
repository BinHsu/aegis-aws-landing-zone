# AWS Landing Zone Lab — AI Operational Rules

> ⚠️ **ACTIVE until 2026-06-12 — aegis multi-account joint-strike.** Canonical plan:
> `aegis-platform-aws/docs/runbooks/2026-06-12-joint-strike.md`. Read it before touching
> org OIDC providers, the `gh-tf-*` SCP glob, or the shared registry account for this
> campaign. (Remove after the window.)

> 📍 **Cross-project rules now live in `~/.claude/CLAUDE.md`** (auto-loads for every repo):
> language · date · bash · safety (a)(h)(i)(k)(m) · externalize-decisions · pre-push-diff ·
> non-host-install · reusable-PII · AWS-tech-blog tone · subagent-delegation · no-hallucination.
> Sections below that restate these are **superseded** (global is source of truth). Durable
> content here = the **repo-specific** part (Terraform/AWS/GHA standards, SCPs-before-resources,
> cost guardrails, ADR/postmortem conventions). *(Deep dup-removal deferred to post-ATMOS.)*

## Communication Rules

- **Artifact Language**: All code, comments, commit messages, documentation, ADRs, runbooks, diagrams, and any file written to the repo MUST be in English. No exceptions.

## Scope — account fabric only

This repository is the **account fabric**, and only the account fabric: AWS Organizations and the OU structure, Service Control Policies, IAM Identity Center (SSO), account bootstrap & vending (the Control-Tower-plus-Terraform hybrid, AFT, the Terraform S3 state backend, the GitHub OIDC identity provider), the org-wide IPAM (the RAM-shared CIDR allocation authority — ADR-012), and the centralized security/audit baseline (CloudTrail organization trail, AWS Config, GuardDuty).

It does **not** own VPC/network, EKS, Karpenter, ArgoCD, cluster add-ons, observability, the edge layer, auth, FIS, IRSA, or workload namespaces/RBAC. Those are a separate Platform tier. Before proposing anything cluster-, workload-, or Kubernetes-shaped, stop — it does not belong here. A change that introduces a billing-while-idle resource (NAT, EKS, ALB, EC2, RDS) is itself a signal the change is in the wrong repo.

## Technical Standards

### Terraform
- **Style**: One module per logical component (organizations, scps, sso, ipam, account-bootstrap, security-baseline)
- **Backend**: S3 with native locking (`use_lockfile = true`), no DynamoDB
- **State isolation**: Separate state file per account per component
- **No hardcoded config in `.tf` files**: Every deployment-specific value (account IDs, emails, **regions** — this one has zero tolerance, see below, CIDRs, AZ names, state bucket name, KMS aliases, remote state bucket/region inside `terraform_remote_state` blocks, etc.) must be read from `config/landing-zone.yaml` via `local.config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))`. If a value *changes per deployment*, it belongs in config. The only acknowledged exception is `backend.tf` — Terraform's backend block does not accept variables; `scripts/configure-backends.sh` templates those from the same config. See ADR-004.
  - **Region strings have zero tolerance**: no `"eu-central-1"` / `"eu-west-1"` / etc. literal anywhere outside `backend.tf`. Always interpolate from `local.primary_region` / `local.config.regions[*]`. This includes IAM policy resource ARNs, CloudWatch log group ARNs, service principals like `logs.<region>.amazonaws.com`, and `provider "aws" { region = ... }` blocks.
  - **Project-identity strings are acceptable to hardcode — with one carve-out for cross-repo collision**: `"aegis"` (organization name) and sibling repo names may appear as literals in **per-repo-scoped** names (RBAC group names, tags, IPAM pool names). Rationale: this repo is *for* Aegis; a forker who wants a different prefix would `sed` the whole repo anyway; the cost of plumbing `local.config.organization.name` through every string is not repaid. **CARVE-OUT for AWS-account-global namespaces shared across sibling repos** — IAM roles, IAM policies, ECR repositories, KMS aliases, S3 buckets, OIDC-trusted roles: prefix with the **full repository name**, `aegis-landing-zone-aws-<resource>` — NOT bare `aegis-<resource>`. A repository name is globally unique by construction (GitHub forbids two repos of the same name under one owner), so the full repo name is the only prefix guaranteed collision-free against every present and future sibling repo sharing the AWS account. The **single exception**: a resource genuinely shared across the *whole AWS environment* and owned by no individual repo — an account-scoped singleton, e.g. the GitHub OIDC identity provider or an account alias — keeps an environment-scoped name rather than a repo-scoped one. Reason: two collisions surfaced 2026-05-14 in the aegis-statefulset sibling repo (`aegis-gha-ci` IAM role, `aegis-stateful-mock` ECR repo) — AI scaffolding defaults to bare `aegis-` in every repo, guaranteeing collision once a second repo lands in the same AWS account. The OIDC provider itself is a singleton per account, owned by landing-zone; sibling repos reuse via `data "aws_iam_openid_connect_provider"`. Existing landing-zone resources with bare `aegis-` prefix (e.g., `aegis-emergency-break-glass`, `aegis-ipam-pools`, `aegis-detective-failed-oidc-assumption`) stay as-is — no churn unless a real second-repo collision surfaces — but **new** resources follow the new convention.
- **Naming**: `snake_case` for resources, descriptive names (e.g., `deny_non_eu_regions`)

### GitHub Actions
- **OIDC only**: No static AWS credentials anywhere. GitHub OIDC → `aws-actions/configure-aws-credentials`. The OIDC trust split is a 2-role model per account — `gh-tf-plan` (read-only, `pull_request`) and `gh-tf-apply-baseline` (`ref:refs/heads/main`); see ADR-014.
- **Workflow pattern**: `plan` on PR (comment plan output), `apply` on merge to main. Every layer in this repo is baseline-tier (negligible always-on cost), so a single `terraform-apply-baseline.yml` auto-applies all of it — there is no separate approval-gated workload workflow.
- **Runners**: GitHub-hosted runners.
- **Rule: AI must wait for ALL CI jobs to pass before merging a PR.** Checkov passing alone is not sufficient — every Terraform Plan job in the matrix must also be green. A partial green is not mergeable. If any job fails, diagnose and fix before merging; do not merge with known failures.

### AWS
- **Region**: `eu-central-1` (Frankfurt) as primary. SCPs deny all other regions except `eu-west-1` (Ireland) as DR.
- **Account naming**: `aegis-management`, `aegis-security`, `aegis-logarchive`, `aegis-shared`, `aegis-staging`, `aegis-prod` (6 accounts per ADR-006).
- **No IAM users**: SSO only for humans, OIDC for GitHub.
- **Tagging**: All resources must have `Project=landing-zone-lab`, `Environment=<env>`, `ManagedBy=terraform`.

### Security
- **SCPs before resources**: Define organizational guardrails before creating any workload.
- **CloudTrail from day one**: Organizational trail in management account → S3 in logarchive account.
- **Encryption default**: S3 SSE-KMS — enabled by default.
- **What is NOT a secret** (safe to commit): AWS account IDs, Organization IDs, OU IDs, IAM role ARNs, SSO start URLs, KMS key ARNs, S3 bucket names. These are metadata — you cannot exploit them without credentials. They appear in `backend.tf` (Terraform language limitation) and commit messages.
- **What IS a secret** (never commit): IAM access keys, secret keys, session tokens, passwords, private keys, OIDC client secrets. This project has zero static credentials by design (SSO for humans, OIDC for GitHub).
- **Deployment-specific values** (gitignored): Account IDs, emails, domain, CIDRs live in `config/landing-zone.yaml` (gitignored). They may also appear in `backend.tf` due to Terraform limitations — use `scripts/configure-backends.sh` to sync from config.

### Architecture Decision Records (ADRs)
- **Location**: `docs/decisions/NNN-title.md`
- **Numbering**: Sequential, zero-padded (001, 002, ...). The current set is 001–016, contiguous.
- **When to write**: Any significant design choice where alternatives were considered.
- **Format**: `# NNN. Title` / `## Status` / `## Context` / `## Decision` / `## Alternatives Considered` / `## Consequences`.
- **Rule: AI agents must check `docs/decisions/` before proposing architecture.** If a decision has already been made and recorded, follow it. If you believe it should change, discuss with the user first — do not silently override.
- **Rule: When a significant design discussion happens in conversation, the AI must remind the user to capture it as an ADR.** Don't let decisions disappear into chat history.

### Incident Postmortems

- **Location**: `docs/incidents.md` (append-only)
- **Format**: Symptom / Root cause / Detection / Resolution / Prevention / Lessons. Each entry is a standalone postmortem.
- **Rule: AI agents must append a new incident entry to `docs/incidents.md` whenever a deployment failure, state-recovery episode, cross-account permission mistake, or other non-trivial gotcha occurs during the session.**
- **Rule: AI must remind the user to record the incident before closing out a debugging session.**
- **Rule: Never edit an existing incident to soften the story after the fact.** Correct factual errors only. The historical record matters more than retroactive polish.

### Layer-specific runbooks

Some Terraservices layers have their own operational contracts that live in `docs/runbooks/NNN-<topic>.md`.

- **Rule: Before running operations in a layer that has its own runbook, AI must read the runbook first.** Current runbooks:
  - `docs/runbooks/001-bootstrap-aws-account.md` — initial AWS / Control Tower / account bootstrap
- **Rule: When adding a new layer whose operations require their own diagnostic order, add a runbook under `docs/runbooks/` rather than extending this file.**

### Operational principles (as distinct from per-layer runbooks)

Some rules are *cross-cutting* — they apply to reviewing any change. These live in `docs/principles/<topic>.md`.

- **Rule: Before opening a PR that touches Terraform provider versions, GitHub Actions workflows, IAM surfaces, or SCPs, AI must read `docs/principles/change-review-discipline.md` and answer the 5-step checklist in the PR description.**
- **Rule: When a new cross-cutting discipline emerges, add a principles doc under `docs/principles/` rather than another CLAUDE.md section.**

## Session-close review (marker-based)

Before suggesting the user close a session, the AI must run:

```bash
grep -rIln "session-close-review:" . --include='*.md' | grep -v node_modules
```

Each file in the result set declares its own review axis via an HTML comment at the top:

```
<!-- session-close-review: <what to check> -->
```

The AI must open each file, read the marker, and verify the axis is up to date against work done in the current session. If the axis is stale, fix it before closing.

Additionally, scan for forgotten placeholders:

```bash
grep -rIn "TODO\|WIP\|coming soon\|not started" . --include='*.md' | grep -v node_modules | grep -v CHANGELOG
```

Any hit that contradicts work shipped in the session is a drift bug — fix it.

**Rule: New session-sensitive docs must add a `<!-- session-close-review: ... -->` marker at the top.**

## Directory Structure

```
aegis-landing-zone-aws/
├── README.md                  # Public entry point (spirit + reading guide + architecture)
├── CLAUDE.md                  # This file — operational rules for AI agents
├── Makefile                   # Local quality gates (dev-setup, fmt, config-check)
├── terraform/
│   └── environments/          # Terraservice layers (one state file per directory)
│       ├── management/{bootstrap,scps}/   # Organizations, OUs, SCPs, Identity Center, detective controls
│       ├── shared/{bootstrap,ipam,aft}/   # shared-account bootstrap; org-wide IPAM; AFT (committed, not applied — ADR-011)
│       ├── staging/bootstrap/             # staging account bootstrap (alias, GitHub OIDC provider, gh-tf-* + break-glass roles)
│       └── prod/bootstrap/                # prod account bootstrap
├── config/
│   ├── landing-zone.example.yaml   # Template for forkers
│   ├── landing-zone.yaml           # Gitignored — actual deployment config
│   └── schema.json                 # JSON Schema for validation
├── scripts/
│   ├── configure-backends.sh       # Sync backend.tf from config
│   ├── configure-github.sh         # Set GitHub Actions + Dependabot secrets
│   ├── validate-config.py          # JSON-Schema-validate config/landing-zone.yaml
│   ├── install-tools.sh            # Install the pinned local toolchain
│   ├── teardown/                   # hard-teardown-landing-zone.sh (project-end only)
│   └── emergency/                  # nuke-workload-account.sh (triple-confirm)
├── .github/
│   ├── workflows/
│   │   ├── terraform-plan.yml
│   │   ├── terraform-apply-baseline.yml
│   │   └── checkov.yml
│   └── dependabot.yml
└── docs/
    ├── architecture.md             # Mermaid diagrams (account topology, OIDC, IPAM, CI/CD)
    ├── design-narrative.md         # Pitch + key decisions + war stories
    ├── interview-notes.md          # Reader's guide for recruiters / architect peers
    ├── finops.md                   # Cost model
    ├── incidents.md                # Append-only postmortems
    ├── decisions/                  # ADRs (NNN-<topic>.md)
    ├── runbooks/                   # Per-layer operational runbooks
    ├── improvements/               # Known gaps + productionization roadmap
    ├── principles/                 # Cross-cutting discipline docs
    └── evidence/                   # Apply / verification evidence
```

Cluster, GitOps, and workload concerns are a separate Platform tier and out of scope here.

## Cost Guardrails

- **Set a daily and a monthly budget cap with alerts in the management account.** The account fabric's always-on cost is ~$5/month (Control Tower + AWS Config recorder + organizational CloudTrail + S3 log storage) plus IPAM advanced tier (~$0 idle — billed per actively-managed IP). There are no per-session cost-incurring layers in this repo: no EKS, no NAT Gateway, no ALB.
- **Rule: AI must check whether a change introduces a cost-incurring resource** (NAT Gateway, EKS, EC2, ALB, RDS, etc.). The account fabric should not grow a billing-while-idle resource without an ADR — and if a proposed change wants one, that is usually a sign the change belongs in the Platform tier, not here.
- **No per-session destroy.** The account fabric is steady-state infrastructure — it is not destroyed between sessions. The only destroy path is the project-end `scripts/teardown/hard-teardown-landing-zone.sh` (triple-confirmed). See ADR-009.
- **Baseline layers auto-apply on merge to main** via `terraform-apply-baseline.yml` — every layer in this repo qualifies.

## Main agent vs subagent: a decision, not a default

**Rule**: The main conversation thread is the human's point of contact — it drives dialog, decisions, and edits. Delegate to subagents only when delegation is net-cheaper than inline execution.

**Delegate when:**
- Output is a summary/answer (human won't read raw tool output)
- Scope is wide: >5 files, cross-directory scans, multi-round grep
- Work is independent of the next conversational turn (use `run_in_background`)
- Investigation is pure recon with no downstream edit dependency

**Stay inline when:**
- <5 tool calls total
- Raw content will be quoted, edited, or referenced verbatim
- Result feeds directly into the next edit (no parallelism gain)
- Human is watching and wants to see each step

**Signal you mis-delegated**: Subagent returns a summary but you have to re-read the files anyway to make the edit. Next time: inline.

**Signal you mis-inlined**: Main thread hit ~30% context on tool output before you even started the real work. Next time: delegate.
