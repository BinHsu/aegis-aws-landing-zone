# Aegis AWS Landing Zone

> Production-grade multi-account AWS landing zone with GitOps, built from scratch as a hands-on portfolio project.

## Purpose

Demonstrate end-to-end ability to design and build enterprise AWS infrastructure from zero:

- Multi-account AWS Organizations with OUs and SCPs
- AWS Control Tower as managed foundation + Terraform for extensions ([ADR-008](docs/decisions/008-landing-zone-tooling-control-tower-hybrid.md))
- AWS Identity Center (SSO) — no IAM users, no static credentials
- GitHub OIDC federation for CI/CD
- Terraform IaC with S3 backend + native locking ([ADR-003](docs/decisions/003-terraform-backend-bootstrap.md))
- GitHub Actions CI/CD (plan on PR, apply on merge)
- EKS cluster with ArgoCD GitOps + Karpenter
- Observability (Prometheus + Grafana)
- Security baseline (CloudTrail, Config, GuardDuty)
- ISO 27001:2022 Annex A as compliance north star ([ADR-005](docs/decisions/005-compliance-framework-iso-27001.md))

## Architecture

```
AWS Organizations (aegis-management)
│
├── OU: Security
│   ├── aegis-security     ← GuardDuty, Security Hub, Config admin
│   └── aegis-logarchive   ← CloudTrail/Config/Flow Log archive (write-only)
│
├── OU: Infrastructure
│   └── aegis-shared       ← Terraform state, AFT, GitHub OIDC, ECR
│
└── OU: Workloads
    ├── aegis-staging      ← Non-production workloads
    └── aegis-prod         ← Production workloads

Regions: eu-central-1 (primary), eu-west-1 (DR)
SCP denies all other regions.
```

See [ADR-006](docs/decisions/006-account-taxonomy-and-ou-structure.md) for the full account taxonomy rationale.

## Configuration Contract

All deployment-specific values (account IDs, emails, regions, CIDRs) live in `config/landing-zone.yaml` (gitignored). A committed template at [`config/landing-zone.example.yaml`](config/landing-zone.example.yaml) shows the expected structure. JSON Schema validation at [`config/schema.json`](config/schema.json) enforces the contract. See [ADR-004](docs/decisions/004-deployment-configuration-contract.md).

**Fork-and-deploy is a config-only operation.** Copy the example, fill in your values, and every Terraform module reads from it.

## Phases

| Phase | Scope | Cost | Status |
|-------|-------|------|--------|
| 0. Bootstrap | AWS account, domain, Control Tower, Identity Center, budget alerts | ~Free | **Done** |
| 1. Foundation | Config contract, Terraform backend, AFT, SCPs, GitHub OIDC | ~Free | **In progress** |
| 2. GitOps Pipeline | GitHub Actions workflows, plan/apply automation, Checkov scanning | ~Free | Not started |
| 3. EKS + ArgoCD + Karpenter | EKS cluster, ArgoCD, Karpenter, cert-manager, Kyverno | ~$5-10/session | Not started |
| 4. Observability + Security | Prometheus, Grafana, CloudTrail, Config, GuardDuty | ~$5-10/session | Not started |
| 5. Enterprise Service Mesh & Auth | Istio (mTLS), EKS Pod Identity, External Secrets, Cognito | ~$1-5/session | Not started |

## Runbooks

- [001 — Bootstrap AWS Account](docs/runbooks/001-bootstrap-aws-account.md): Step-by-step from zero to SSO-authenticated CLI, including Control Tower setup, KMS key policy, Identity Center, and all gotchas encountered.

## Architecture Decision Records

| ADR | Decision |
|-----|----------|
| [001](docs/decisions/001-landing-zone-scope-boundary.md) | Landing zone scope boundary |
| [002](docs/decisions/002-region-and-availability-zone-strategy.md) | Region and Availability Zone strategy |
| [003](docs/decisions/003-terraform-backend-bootstrap.md) | Terraform backend bootstrap and state layout |
| [004](docs/decisions/004-deployment-configuration-contract.md) | Deployment configuration contract |
| [005](docs/decisions/005-compliance-framework-iso-27001.md) | Compliance framework — ISO 27001 |
| [006](docs/decisions/006-account-taxonomy-and-ou-structure.md) | Account taxonomy and OU structure |
| [007](docs/decisions/007-infra-app-repository-split.md) | Infrastructure / application repository split |
| [008](docs/decisions/008-landing-zone-tooling-control-tower-hybrid.md) | Landing zone tooling — Control Tower + Terraform hybrid |
| [009](docs/decisions/009-lifecycle-and-teardown-strategy.md) | Lifecycle and teardown strategy |

## Companion Application Repository

This infrastructure repo is the **Pointer** — it defines VPCs, EKS clusters, OIDC, and hoists ArgoCD. The application workload lives in **[aegis-core](https://github.com/BinHsu/aegis-core)** (the **Payload**). ArgoCD watches `aegis-core` and deploys changes via pull-based GitOps. See [ADR-007](docs/decisions/007-infra-app-repository-split.md).

## Cost Management

- **Phase 0-2 are essentially free** (Organizations, SSO, SCPs, S3, GitHub Actions free tier)
- **Phase 3+ costs money** — spin up only when practicing, destroy after every session via [`soft-teardown-workload.sh`](docs/decisions/009-lifecycle-and-teardown-strategy.md)
- **Budget alerts**: daily $10, monthly $30
- **NAT Gateway is the hidden cost killer** ($0.045/hr = $32/month if left running)
- **Persistent baseline**: ~$5/month (Control Tower + Config recorder + CloudTrail)
- **Per-session ephemeral**: ~$1-2/session (EKS, NAT, compute)

## Prerequisites

- AWS account (management account) with billing access
- Domain registered with email routing (see [runbook](docs/runbooks/001-bootstrap-aws-account.md))
- Terraform CLI >= 1.10.0 (`brew install terraform`)
- AWS CLI v2 (`brew install awscli`)
- kubectl (`brew install kubectl`)

## Directory Structure

```
aegis-aws-landing-zone/
├── config/
│   ├── landing-zone.example.yaml  # Template (committed)
│   ├── landing-zone.yaml          # Real values (gitignored)
│   └── schema.json                # JSON Schema validation
├── terraform/
│   └── environments/
│       ├── management/bootstrap/  # Management account baseline
│       ├── shared/bootstrap/      # State bucket, IPAM (future)
│       ├── staging/               # Staging layers (future)
│       └── prod/                  # Production layers (future)
├── docs/
│   ├── decisions/                 # Architecture Decision Records
│   └── runbooks/                  # Operational runbooks
├── .github/workflows/             # GitHub Actions (future)
├── k8s-manifests/                 # ArgoCD app-of-apps (future)
├── CLAUDE.md                      # AI operational rules
└── .terraform-version             # Pinned Terraform version
```

## Author

**Bin Hsu** — Senior Software Architect, 15 years experience (10 years C++ embedded systems, 5 years AWS platform engineering). Building this to prove that system design + hands-on implementation = the same person.
