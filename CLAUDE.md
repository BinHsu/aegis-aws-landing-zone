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
- **Variables**: Use `tfvars` files per environment, never hardcode account IDs or regions
- **Naming**: `snake_case` for resources, descriptive names (e.g., `deny_non_eu_regions`)

### GitHub Actions
- **OIDC only**: No static AWS credentials anywhere. GitHub OIDC → `aws-actions/configure-aws-credentials`
- **Workflow pattern**: `plan` on PR (comment plan output), `apply` on merge to main
- **Self-hosted runners**: Phase 3+ (EKS-based). Use GitHub-hosted runners for Phase 1-2

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

- **Rule: When adding a new layer whose operations require their own diagnostic order (e.g., observability, service mesh), add a runbook under `docs/runbooks/` rather than extending this file.** Keeping CLAUDE.md small preserves its discoverability; layer-specific details belong with the layer.

## Directory Structure

```
aws-landing-zone-lab/
├── README.md
├── CLAUDE.md
├── terraform/
│   ├── modules/
│   │   ├── organizations/     # AWS Organizations, OUs, accounts
│   │   ├── scp/               # Service Control Policies
│   │   ├── sso/               # AWS Identity Center
│   │   ├── oidc-github/       # GitHub OIDC provider
│   │   ├── terraform-backend/ # S3 bucket + state config
│   │   ├── vpc/               # VPC per account
│   │   ├── eks/               # EKS cluster
│   │   └── argocd/            # ArgoCD Helm deployment
│   ├── environments/
│   │   ├── management/        # Management account resources
│   │   ├── security/          # Security account resources
│   │   ├── staging/           # Staging account resources
│   │   └── prod/              # Production account resources
│   └── backend.tf             # Bootstrap backend config
├── k8s-manifests/
│   ├── argocd/                # ArgoCD app-of-apps
│   ├── monitoring/            # Prometheus + Grafana
│   └── apps/                  # Sample application
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml
│       └── terraform-apply.yml
├── docs/
│   ├── architecture.md
│   ├── phase1.md              # Phase 1 spec + design considerations
│   ├── phase2.md              # Phase 2 spec
│   ├── phase3.md              # Phase 3 spec
│   ├── phase4.md              # Phase 4 spec
│   └── decisions/             # ADRs (Architecture Decision Records)
│       ├── 001-management-account-scope.md
│       ├── 002-shared-services-account.md
│       └── 003-multi-region-strategy.md
└── README.md
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
