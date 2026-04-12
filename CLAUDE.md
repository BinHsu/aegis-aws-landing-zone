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

- **NEVER leave EKS, NAT Gateway, or ALB running overnight.** Always `terraform destroy` after practice.
- **Set AWS Budget alert at $10/day** before creating any resources.
- **Phase 1-2 should cost <$5 total.** If costs exceed this, something is wrong — investigate.
- **Phase 3-4: budget ~$5-10 per practice session** (4 hours). Destroy everything after.

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
