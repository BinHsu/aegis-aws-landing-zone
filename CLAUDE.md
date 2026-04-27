# AWS Landing Zone Lab — AI Operational Rules

## Communication Rules

- **Artifact Language**: All code, comments, commit messages, documentation, ADRs, runbooks, diagrams, and any file written to the repo MUST be in English. No exceptions.

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
  - `docs/runbooks/006-grafana-cloud-onboarding.md` — Grafana Cloud free tier signup, bootstrap/downstream token rotation, scope-isolation verification (MUST read when provisioning a fresh stack, rotating any token, or migrating regions)
  - `docs/runbooks/007-qdrant-cloud-onboarding.md` — Qdrant Cloud free tier signup, API key rotation, manual SSM PS credential stash ahead of TF scaffolding per ADR-025 (MUST read when provisioning a fresh cluster or rotating the API key)
  - `docs/runbooks/008-cognito-user-pool-onboarding.md` — Cognito User Pool first-time provisioning, first-user creation via `admin-create-user`, Hosted UI login verification, JWKS token smoke test; MUST read before the first `terraform apply` on `staging/auth/` or before creating any new admin user

- **Rule: When adding a new layer whose operations require their own diagnostic order (e.g., observability, service mesh), add a runbook under `docs/runbooks/` rather than extending this file.** Keeping CLAUDE.md small preserves its discoverability; layer-specific details belong with the layer.

### Operational principles (as distinct from per-layer runbooks)

Some rules are *cross-cutting* — they apply to reviewing any platform change, not just one layer. These live in `docs/principles/<topic>.md`.

- **Rule: Before opening a PR that touches cluster components, Terraform provider versions, GitHub Actions workflows, IAM surfaces, or SCPs, AI must read `docs/principles/change-review-discipline.md` and answer the 5-step checklist in the PR description.** The checklist (blast radius / dependency assumptions / deprecation status / rollback plan / 2 AM readability) is short by design — if answering takes more than a paragraph per step, the PR is probably too big. Deprecation status specifically must reference the upstream upgrade guide (Terraform provider, Kubernetes API, GitHub Action) so future-me or a forker can trace how "deprecated" was determined at PR time, not after.

- **Rule: When a new cross-cutting discipline emerges that applies to multiple layers (e.g., observability, security posture, release engineering), add a principles doc under `docs/principles/` rather than another CLAUDE.md section.** Same motivation as runbooks: this file stays small, subject-matter details live where the subject lives.

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
│       ├── staging/{bootstrap,secrets-persistent,auth,network,platform,workloads,observability,edge,fis}/   # secrets-persistent = Path-B SaaS-credential SSM PS shells excluded from teardown matrix (ADR-028); auth = Cognito User Pool (ADR-026); platform = EKS + Karpenter + ArgoCD + Kyverno + cert-manager + ESO/CRDs/KSM/Alloy; observability = grafana-operator + GC tokens (ADR-022); edge = CloudFront + ACM + Route53 (ADR-019); fis = DR drill (ADR-020)
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
    ├── decisions/                  # 26 ADRs (NNN-<topic>.md)
    ├── runbooks/                   # 6 per-layer operational runbooks
    ├── principles/                 # Cross-cutting discipline docs (change-review, break-glass-apply)
    └── personal/                   # Gitignored — private portfolio brief
```

## Cost Guardrails

- **NEVER leave EKS, NAT Gateway, or ALB running overnight.** Always run the soft teardown at session end.
- **Set a daily and a monthly budget cap with alerts in the management account.** Specific numbers are deployment-dependent; pick values that sting if a NAT Gateway runs over a weekend.
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
