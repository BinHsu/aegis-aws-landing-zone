# AWS Landing Zone Lab — AI Operational Rules

## Project Context

This is a hands-on portfolio project by **Bin Hsu**, a Senior Software Architect with 15 years of experience (10 years C++ embedded systems at VIVOTEK, 5 years AWS platform engineering at E2 Nova). The project exists to:

1. **Prove hands-on ability** — after interview feedback that he "doesn't code enough," this project demonstrates he can design AND implement production-grade infrastructure from scratch.
2. **Fill skill gaps** — practice GitHub Actions (previously Jenkins), ArgoCD (previously push-based CI/CD), and Go (learning).
3. **Create a portfolio piece** — a GitHub repo that any interviewer can review.

## Bin's Existing Experience (don't re-explain these)

- AWS: 5 accounts, 3 regions, 479 CloudFormation templates, 6 Terraform modules, AWS SAP certified
- Kubernetes: EKS, 15 Helm charts, Karpenter, LION-UT ephemeral test environments
- CI/CD: 155 Jenkins pipelines (38,900 lines Groovy/Shell)
- Observability: Prometheus → Grafana IaC pipeline (12 alert rules as Helm → ConfigMap → sidecar)
- Security: ISO 27001/27701 3 years, SCPs, cross-account IAM, IRSA, Zero Trust (SSO migration)
- Databases: MySQL/Aurora, ProxySQL connection pooling

## What's NEW for Bin (learning goals)

- GitHub Actions (replacing Jenkins knowledge)
- ArgoCD (replacing push-based deployment)
- GitHub OIDC → AWS (replacing long-lived IAM keys)
- AWS Organizations setup from scratch (previously inherited)
- Terraform S3 native locking (previously DynamoDB)

## Communication Rules

- **Artifact Language**: All code, comments, commit messages, documentation, ADRs, runbooks, diagrams, and any file written to the repo MUST be in English. No exceptions.
- **Conversation Language**: AI mirrors the language the user types in.
  - User types English → AI responds in English.
  - User types Chinese (Traditional) → AI responds in Chinese (Traditional).
  - If a message mixes languages, AI responds in whichever language dominates the user's message.
  - Language switching is per-message: the AI re-evaluates on every turn, not once per session.
- **Technical terms stay in English** even in Chinese replies (e.g., "Terraform", "SCP", "break-glass", "burn-rate alert") — do not translate industry terminology.
- **English Correction**: When the user types in English, flag any incorrect or unnatural phrasing with a corrected version. Do not correct Chinese input.

## Technical Standards

### Terraform
- **Style**: One module per logical component (organizations, sso, scp, vpc, eks, argocd)
- **Backend**: S3 with native locking (`use_lockfile = true`), no DynamoDB
- **State isolation**: Separate state file per account per component
- **No hardcoded config in `.tf` files**: Every deployment-specific value (account IDs, emails, **regions** — this one has zero tolerance, see below, CIDRs, AZ names, state bucket name, KMS aliases, remote state bucket/region inside `terraform_remote_state` blocks, etc.) must be read from `config/landing-zone.yaml` via `local.config = yamldecode(file("${path.root}/../../../../config/landing-zone.yaml"))`. If a value *changes per deployment*, it belongs in config. The only acknowledged exception is `backend.tf` — Terraform's backend block does not accept variables; `scripts/configure-backends.sh` templates those from the same config. See ADR-004.
  - **Region strings have zero tolerance**: no `"eu-central-1"` / `"eu-west-1"` / etc. literal anywhere outside `backend.tf`. Always interpolate from `local.primary_region` / `local.dr_region` / `local.config.regions[*]`. This includes IAM policy resource ARNs, CloudWatch log group ARNs, service principals like `logs.<region>.amazonaws.com`, and — critically — `provider "aws" { region = ... }` blocks.
  - **Project-identity strings are acceptable to hardcode**: `"aegis"` (organization name) and `"aegis-core"` (sibling repo name) may appear as literals in resource names, S3 bucket names, K8s RBAC group names, etc. Rationale: this repo is *for* Aegis; a forker who wants a different prefix would `sed` the whole repo anyway. The cost of plumbing `local.config.organization.name` through every string is not repaid.
  - **Provider aliases (ADR-018 §3)**: `alias =` is a static HCL identifier and cannot be config-driven. Use **role-based labels** (`primary`, `slave_1`, `slave_2`) and drive `region =` from `local.config.regions[*]` so the *value* comes from config even if the *label* cannot. This is the **slot pattern**. The repo commits to a fixed ceiling K (currently K=2 for EKS, declared in `staging/platform/providers.tf`). Growing 1 → K is a pure config change; growing beyond K requires adding one provider block + one module invocation + an ADR amendment. Breaking past the slot pattern entirely (truly dynamic N) means migrating to a `scripts/configure-providers.sh` template — which is a separate ADR and a separate discussion.
- **Naming**: `snake_case` for resources, descriptive names (e.g., `deny_non_eu_regions`)

### GitHub Actions
- **OIDC only**: No static AWS credentials anywhere. GitHub OIDC → `aws-actions/configure-aws-credentials`
- **Workflow pattern**: `plan` on PR (comment plan output), `apply` on merge to main
- **Self-hosted runners**: Phase 3+ (EKS-based). Use GitHub-hosted runners for Phase 1-2
- **Rule: AI must wait for ALL CI jobs to pass before merging a PR.** Checkov passing alone is not sufficient — every Terraform Plan job in the matrix must also be green. A partial green (e.g., Checkov pass + 4 plan pending) is not mergeable. If any job fails, diagnose and fix before merging; do not merge with known failures.

### AWS
- **Region**: `eu-central-1` (Frankfurt) as primary. SCPs deny all other regions except `eu-west-1` (Ireland) as DR
- **Account naming**: `aegis-management`, `aegis-security`, `aegis-logarchive`, `aegis-shared`, `aegis-staging`, `aegis-prod` (6 accounts per ADR-006; `aegis-logarchive` and `aegis-shared` are added versus the original 4-account sketch)
- **No IAM users**: SSO only for humans, OIDC for GitHub, IRSA for K8s workloads
- **Tagging**: All resources must have `Project=landing-zone-lab`, `Environment=<env>`, `ManagedBy=terraform`

### ArgoCD
- **App-of-apps pattern**: One root Application that manages all other Applications
- **Repo structure**: `k8s-manifests/{app}/{env}/` with Kustomize overlays
- **Sync policy**: Auto-sync for staging, manual sync for prod

### Security
- **SCPs before resources**: Define organizational guardrails before creating any workload
- **CloudTrail from day one**: Organizational trail in management account → S3 in security account
- **Encryption default**: S3 SSE-KMS, EBS encryption, RDS encryption — all enabled by default
- **What is NOT a secret** (safe to commit): AWS account IDs, Organization IDs, OU IDs, IAM role ARNs, SSO start URLs, KMS key ARNs, S3 bucket names. These are metadata — you cannot exploit them without credentials. They appear in `backend.tf` (Terraform language limitation) and commit messages.
- **What IS a secret** (never commit): IAM access keys, secret keys, session tokens, passwords, private keys, OIDC client secrets. This project has zero static credentials by design (SSO for humans, OIDC for GitHub, IRSA for K8s).
- **Deployment-specific values** (gitignored): Account IDs, emails, domain, CIDRs live in `config/landing-zone.yaml` (gitignored). They may also appear in `backend.tf` due to Terraform limitations — use `scripts/configure-backends.sh` to sync from config.

### Architecture Decision Records (ADRs)
- **Location**: `docs/decisions/NNN-title.md`
- **Numbering**: Sequential, zero-padded (001, 002, ...)
- **When to write**: Any significant design choice where alternatives were considered — account placement, tooling choices, multi-region strategy, etc.
- **Format**:
  ```
  # NNN. Title
  ## Status
  Accepted | Superseded by NNN | Deprecated
  ## Context
  What problem are we solving? What constraints exist?
  ## Decision
  What we chose and why.
  ## Alternatives Considered
  What we rejected and why.
  ## Consequences
  Tradeoffs we accept. What becomes easier/harder.
  ```
- **Rule: AI agents must check `docs/decisions/` before proposing architecture.** If a decision has already been made and recorded, follow it. If you believe it should change, discuss with the user first — do not silently override.
- **Rule: When a significant design discussion happens in conversation, the AI must remind the user to capture it as an ADR.** Don't let decisions disappear into chat history.

### Incident Postmortems

- **Location**: `docs/incidents.md` (append-only)
- **Format**: Symptom / Root cause / Detection / Resolution / Prevention / Lessons. Each entry is a standalone postmortem, scannable independently.
- **Rule: AI agents must append a new incident entry to `docs/incidents.md` whenever a deployment failure, state-recovery episode, cross-account permission mistake, or other non-trivial gotcha occurs during the session.** The entry is written after the fact, with the benefit of hindsight, in the existing format.
- **Rule: Runbook troubleshooting entries are in addition to, not instead of, the postmortem.** The runbook tells future operators "if you see X, do Y"; the incident log tells them "here's the full story of why X happens and how we found it." Both matter.
- **Rule: AI must remind the user to record the incident before closing out a debugging session.** Untracked incidents are technical debt — the next operator (including future Claude) will repeat the mistake if it is not written down.
- **Rule: Never edit an existing incident to soften the story after the fact.** Correct factual errors only. The historical record matters more than retroactive polish.

### Layer-specific runbooks

Some Terraservices layers have their own operational contracts — pre-flight checks, connectivity failure diagnostics, update procedures — that do not belong in global rules because they only apply when working in that layer. These live in `docs/runbooks/NNN-<topic>.md`.

- **Rule: Before running operations in a layer that has its own runbook, AI must read the runbook first.** The runbook is the authoritative source for that layer's pre-flight checks and failure diagnostics. Global rules (this file) point at the runbook; they do not duplicate it. Scanning the runbook costs a few seconds; skipping it and debugging in the wrong order costs tens of minutes. Current runbooks:
  - `docs/runbooks/001-bootstrap-aws-account.md` — initial AWS / Control Tower bootstrap
  - `docs/runbooks/002-eks-access.md` — EKS operator access (MUST read before any `kubectl`, `aws eks`, or `staging/platform` apply in a session)
  - `docs/runbooks/003-platform-first-verification.md` — end-to-end checklist after `staging/platform` applies; links to Incidents 10–17 for cold-apply gotchas (MUST follow for any fresh apply of the platform layer)
  - `docs/runbooks/004-dns-delegation-cloudflare-to-route53.md` — Cloudflare-side subdomain NS delegation to a Route53 hosted zone; one-time setup + rollback + troubleshooting (MUST read when provisioning `staging/edge/` or any future env's edge Terraservice)
  - `docs/runbooks/005-fis-dr-drill.md` — FIS DR drill execution (ADR-020); pre-flight checks, experiment start/observe/recover, troubleshooting (MUST read before `aws fis start-experiment` against any env)

- **Rule: When adding a new layer whose operations require their own diagnostic order (e.g., observability, service mesh), add a runbook under `docs/runbooks/` rather than extending this file.** Keeping CLAUDE.md small preserves its discoverability; layer-specific details belong with the layer.

### Operational principles (as distinct from per-layer runbooks)

Some rules are *cross-cutting* — they apply to reviewing any platform change, not just one layer. These live in `docs/principles/<topic>.md`.

- **Rule: Before opening a PR that touches cluster components, Terraform provider versions, GitHub Actions workflows, IAM surfaces, or SCPs, AI must read `docs/principles/change-review-discipline.md` and answer the 5-step checklist in the PR description.** The checklist (blast radius / dependency assumptions / deprecation status / rollback plan / 2 AM readability) is short by design — if answering takes more than a paragraph per step, the PR is probably too big. Deprecation status specifically must reference the upstream upgrade guide (Terraform provider, Kubernetes API, GitHub Action) so future-me or a forker can trace how "deprecated" was determined at PR time, not after.

- **Rule: When a new cross-cutting discipline emerges that applies to multiple layers (e.g., observability, security posture, release engineering), add a principles doc under `docs/principles/` rather than another CLAUDE.md section.** Same motivation as runbooks: this file stays small, subject-matter details live where the subject lives.

### Cross-repo coordination (landing-zone ↔ aegis-core)

This repository shares a lifecycle boundary with [aegis-core](https://github.com/BinHsu/aegis-core) — the app-side repository that ArgoCD syncs from. The two repos are maintained by independent agents and must coordinate through durable artifacts, not direct IPC.

- **Rule: Cross-repo coordination lives in GitHub Issues labeled `cross-repo`.** Two standing issues (do not close; edit body to maintain):
  - [#54 Platform surface contract (landing-zone)](https://github.com/BinHsu/aegis-aws-landing-zone/issues/54) — what aegis-core can assume
  - [#11 Requirements from landing-zone (aegis-core)](https://github.com/BinHsu/aegis-core/issues/11) — what aegis-core needs

- **Rule: At session start for any work that touches the platform contract** (CRDs, namespaces, IRSA, `staging/platform/`), AI must run both:
  ```
  gh issue list -l cross-repo -R BinHsu/aegis-aws-landing-zone
  gh issue list -l cross-repo -R BinHsu/aegis-core
  ```
  Any issue labeled `cross-repo/blocking` on either side halts planning until acknowledged.

- **Rule: When this repo changes the platform surface contract**, the PR must (a) update the #54 issue body to reflect the new state, and (b) carry label `cross-repo/blocking` if the change would break aegis-core's existing assumptions.

- **Label semantics**:
  - `cross-repo` — default coordination tag (standing issues + long-lived threads)
  - `cross-repo/blocking` — the other side is blocked until this lands / is acknowledged
  - `cross-repo/fyi` — informational only; no action required

- **Rule: Do NOT implement a cross-repo request before the other side's issue arrives.** The issue is the requirements document, not just a notification. The other side may specify security constraints (least-privilege roles vs shared admin), blast radius boundaries, or future-proofing requirements that fundamentally change the implementation. Acknowledge the gap, note what needs to happen, but do not write code until the spec is in hand. "Obvious" fixes that skip this gate have caused wasted PR cycles and briefly-incorrect trust policies (see PR #73 → #72 lesson).

- **Anti-pattern**: direct agent-to-agent messaging, shared memory mounts, or any ephemeral channel. The audit trail is the point.

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

**Rule: New session-sensitive docs must add a `<!-- session-close-review: ... -->` marker at the top.** This is opt-in: if a doc does not declare a marker, it is not reviewed at session close. The marker is the single source of truth for what needs per-session attention — CLAUDE.md does not hardcode filenames.

## Directory Structure

```
aws-landing-zone-lab/
├── README.md                  # Public entry point (spirit + reading guide + architecture)
├── CLAUDE.md                  # This file — operational rules for AI agents
├── terraform/
│   └── environments/          # Terraservice layers (one state file per directory)
│       ├── management/{bootstrap,scps}/
│       ├── shared/{bootstrap,ipam}/   # shared/aft/ committed but not applied (ADR-011)
│       ├── staging/{bootstrap,network,platform,workloads,edge,fis}/   # platform = EKS + Karpenter + ArgoCD + Kyverno + cert-manager; fis = DR drill (ADR-020)
│       └── prod/bootstrap/    # prod workloads not yet provisioned
├── k8s-manifests/             # App-of-apps root (details live in aegis-core repo)
├── config/
│   ├── landing-zone.example.yaml   # Template for forkers
│   ├── landing-zone.yaml           # Gitignored — actual deployment config
│   └── schema.json                 # JSON Schema for validation
├── scripts/
│   ├── configure-backends.sh       # Sync backend.tf from config
│   ├── configure-github.sh         # Set GitHub Actions + Dependabot secrets
│   ├── validate-config.py          # JSON-Schema-validate config/landing-zone.yaml
│   ├── teardown/                   # Soft / hard / emergency teardown scripts
│   └── emergency/                  # nuke-workload-account.sh (triple-confirm)
├── .github/
│   ├── workflows/
│   │   ├── terraform-plan.yml
│   │   ├── terraform-apply-baseline.yml
│   │   ├── terraform-apply-workload.yml
│   │   ├── terraform-teardown-workload.yml
│   │   └── checkov.yml
│   └── dependabot.yml
└── docs/
    ├── architecture.md             # Mermaid diagrams (account topology, CI/CD, IPAM, etc.)
    ├── design-narrative.md         # 2-minute pitch + key decisions + war stories
    ├── interview-notes.md          # Reader's guide for recruiters / architect peers
    ├── incidents.md                # Append-only postmortems (32 as of 2026-04-21; unchanged this session)
    ├── decisions/                  # 23 ADRs (NNN-<topic>.md)
    ├── runbooks/                   # 6 per-layer operational runbooks
    ├── principles/                 # Cross-cutting discipline docs (change-review, break-glass-apply)
    └── personal/                   # Gitignored — private portfolio brief
```

## Cost Guardrails

- **NEVER leave EKS, NAT Gateway, or ALB running overnight.** Always run the soft teardown at session end.
- **Budget alerts**: daily $10, monthly $30, enforced via AWS Budgets in the management account. See memory.
- **Phase 0-2 should cost <$5 total.** If Phase 0-2 costs exceed this, something is wrong — investigate before continuing.
- **Phase 3+: budget ~$5-10 per 4-hour session.** A session is framed as "from `gh workflow run terraform-apply-workload.yml` until `gh workflow run terraform-teardown-workload.yml`." Both are approval-gated via GitHub Environments.
- **Rule: AI must remind the user to run the workload teardown at the end of any session that applied workload layers.** Preferred path (portfolio-visible audit trail):
  ```
  gh workflow run terraform-teardown-workload.yml -f env=<env>
  gh run watch   # then approve when GitHub prompts
  ```
  Fallback if CI unavailable: `./scripts/teardown/soft-teardown-workload.sh <env>` (same effect locally). Not optional — a session that applied workload layers and ends without a teardown reminder is a cost incident waiting to happen.
- **Rule: Workload layers are NOT auto-applied on merge to main.** Baseline layers (bootstrap, scps, ipam) apply automatically via `terraform-apply-baseline.yml`. Cost-incurring layers (network, platform, workloads) require explicit `gh workflow run terraform-apply-workload.yml -f env=<env>` with human approval. Changing this without an ADR is a design regression.
- **Rule: AI must check whether a cost-incurring resource is about to be created** (NAT Gateway, EKS cluster, EC2, ALB, RDS, etc.) and explicitly note the hourly/monthly cost before proceeding to `terraform apply`. "Cost-incurring" means anything that bills while idle; storage and request-based pricing are lower-priority reminders.

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

## Workflow with AI

The user (Bin) provides:
- **Architecture decisions** — what to build, why, tradeoffs
- **AWS account access** — credentials, account IDs
- **Review and deployment** — runs `terraform apply`, validates results

The AI provides:
- **Implementation** — Terraform code, GitHub Actions workflows, Helm values
- **Best practices** — security patterns, cost optimization, naming conventions
- **Explanations** — why each design choice matters (for interview prep)

**Rule: The user must understand every line of code before deploying it.** This is a learning project, not a copy-paste exercise. If the user doesn't understand something, explain it before moving on.

**Rule: Do NOT write code or create files until the user explicitly says to start.** Default mode is discuss and plan. Only begin implementation when the user gives a clear go-ahead (e.g., "動手", "開始", "go", "start building").
