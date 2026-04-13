# Architecture

This document is the authoritative visual reference for the `aegis-aws-landing-zone` deployment. Every diagram is **Mermaid** (text-based, GitHub-rendered) — no static images, no external renderers, no drift risk. Edit the diagram when you edit the code.

Each diagram is cross-referenced to the Architecture Decision Record (ADR) that owns the underlying reasoning. When the diagram and an ADR disagree, the ADR wins and the diagram needs fixing in the same PR.

---

## 1. Account Topology

AWS Organizations structure with the six accounts, three OUs, and SCP attachment point. See [ADR-006](decisions/006-account-taxonomy-and-ou-structure.md) for rationale.

```mermaid
flowchart TB
  Org["AWS Organization<br/>o-f5xi4j1hrx<br/>Control Tower home: eu-central-1"]

  Mgmt["aegis-management<br/><br/>Organizations<br/>SCPs<br/>Identity Center<br/>Billing<br/>RAM org-sharing"]

  subgraph Security["OU: Security (Control Tower-managed)"]
    Sec["aegis-security<br/><br/>GuardDuty<br/>Security Hub<br/>Config admin"]
    Log["aegis-logarchive<br/><br/>CloudTrail archive<br/>Config archive<br/>VPC Flow Logs"]
  end

  subgraph Infra["OU: Infrastructure"]
    Shared["aegis-shared<br/><br/>Terraform state bucket<br/>IPAM pools<br/>GitHub OIDC<br/>AFT (not deployed)"]
  end

  subgraph Work["OU: Workloads"]
    Stg["aegis-staging<br/><br/>Phase 3: EKS (planned)"]
    Prd["aegis-prod<br/><br/>Phase 3: EKS (planned)"]
  end

  Org --> Mgmt
  Org --> Security
  Org --> Infra
  Org --> Work
  Mgmt -. SCPs .-> Security
  Mgmt -. SCPs .-> Infra
  Mgmt -. SCPs .-> Work
```

**Custom SCPs attached to Root** (see [ADR](decisions/006-account-taxonomy-and-ou-structure.md) and [terraform/environments/management/scps](../terraform/environments/management/scps/)):

- `deny-root-user-actions` — blocks root in member accounts (ISO 27001 A.8.2)
- `deny-iam-user-creation` — SSO-only access (ISO 27001 A.8.2)
- `deny-leave-organization` — prevents accidental detach (ISO 27001 A.5.1)

Plus Control Tower's mandatory guardrails (Region deny, CloudTrail/Config protection).

---

## 2. CI/CD Data Flow

How changes flow from a developer's laptop to deployed AWS resources, with zero static credentials. See [ADR-001](decisions/001-landing-zone-scope-boundary.md) (no-static-credentials principle) and [.github/workflows/](../.github/workflows/).

```mermaid
sequenceDiagram
  actor Dev as Developer
  participant GH as GitHub
  participant GHA as GitHub Actions
  participant OIDC as AWS STS<br/>(OIDC federation)
  participant TF as Terraform
  participant AWS as AWS Account<br/>(management/shared/staging)

  Dev->>GH: git push (signed commits)
  Dev->>GH: open PR to main
  GH->>GHA: trigger terraform-plan + checkov
  GHA->>OIDC: AssumeRoleWithWebIdentity<br/>(repo subject claim)
  OIDC-->>GHA: 1-hour temporary credentials
  GHA->>TF: terraform plan
  TF->>AWS: read current state + dry-run changes
  AWS-->>TF: plan output
  TF-->>GHA: plan result
  GHA->>GH: post plan as PR comment

  Note over Dev,GH: Review plan, resolve findings, approve

  Dev->>GH: merge PR (signed merge commit)
  GH->>GHA: trigger terraform-apply
  GHA->>OIDC: same OIDC flow, main-branch subject
  GHA->>TF: terraform apply -auto-approve
  TF->>AWS: create/update/destroy resources
  AWS-->>TF: applied state
```

**Required status checks on main** (branch protection): 5× `Plan ${env}` + `Checkov IaC Security Scan`. See [Runbook Part 10.3](runbooks/001-bootstrap-aws-account.md).

---

## 3. Identity and Access

Who can do what, and how they authenticate. Zero IAM users. Zero long-lived credentials. See [ADR-001](decisions/001-landing-zone-scope-boundary.md).

```mermaid
flowchart LR
  subgraph Human["Human Access"]
    bin["Identity Center user: bin<br/>pcpunkhades@gmail.com"]
    ps["Permission Set:<br/>PlatformAdmin<br/>(AdministratorAccess policy)"]
  end

  subgraph CI["CI/CD Access (no static creds)"]
    gha["GitHub Actions workflow<br/>BinHsu/aegis-aws-landing-zone"]
    oidc["token.actions<br/>.githubusercontent.com"]
  end

  subgraph AWS["AWS IAM Principals"]
    sso_roles["AWSReservedSSO_PlatformAdmin_*<br/>(4 accounts: management,<br/>shared, staging, prod)"]
    ci_roles["github-actions-terraform<br/>(3 accounts: management,<br/>shared, staging)"]
  end

  bin --> ps
  ps -->|aws sso login<br/>8h session| sso_roles
  gha --> oidc
  oidc -->|AssumeRoleWithWebIdentity<br/>15min OIDC token → 1h creds| ci_roles

  style Human fill:#e3f2fd,stroke:#1976d2
  style CI fill:#fff3e0,stroke:#e65100
  style AWS fill:#e8f5e9,stroke:#2e7d32
```

**Forbidden (enforced by SCP `deny-iam-user-creation`):** creating IAM users, creating access keys, attaching user policies.

---

## 4. State and IPAM (Shared Services)

What lives in the `aegis-shared` account, and how other accounts consume its services. See [ADR-003](decisions/003-terraform-backend-bootstrap.md), [ADR-004](decisions/004-deployment-configuration-contract.md), [ADR-012](decisions/012-vpc-topology-and-egress-strategy.md).

```mermaid
flowchart TB
  subgraph shared["aegis-shared (345895787808)"]
    direction TB

    bucket["S3: aegis-terraform-state-345895787808<br/>SSE-KMS + versioning<br/>30-day noncurrent expiration<br/>prevent_destroy"]

    ipam["AWS IPAM (Advanced tier)"]
    top["Top Pool: 10.0.0.0/8"]
    primary_pool["Regional Pool eu-central-1<br/>10.0.0.0/12"]
    dr_pool["Regional Pool eu-west-1<br/>10.16.0.0/12"]

    ram["RAM share: aegis-ipam-pools<br/>(org-scoped)"]

    ipam --> top
    top --> primary_pool
    top --> dr_pool
    primary_pool --> ram
    dr_pool --> ram
  end

  subgraph consumers["Consumer accounts (via OrgID condition)"]
    mgmt["management: reads/writes<br/>management/bootstrap/tfstate<br/>management/scps/tfstate"]
    stg["staging: reads/writes<br/>staging/bootstrap/tfstate<br/>+ allocates from IPAM pools<br/>(Phase 3)"]
    prd["prod: same pattern<br/>(Phase 3+)"]
  end

  bucket -. s3:GetObject + PutObject<br/>condition: aws:PrincipalOrgID .-> mgmt
  bucket -. same .-> stg
  bucket -. same .-> prd
  ram -. allocate-cidr .-> stg
  ram -. allocate-cidr .-> prd
```

**State key convention:** `<account>/<layer>/terraform.tfstate`. Currently live: management/bootstrap, management/scps, shared/bootstrap, shared/ipam, staging/bootstrap, prod/bootstrap.

---

## 5. Deployment Order and Dependencies

Which Terraform layers must apply first. Encoded in [`.github/workflows/terraform-apply.yml`](../.github/workflows/terraform-apply.yml).

```mermaid
flowchart LR
  A["1. management/<br/>bootstrap"]
  B["2. shared/<br/>bootstrap"]
  C["3. shared/<br/>ipam"]
  D["4. staging/<br/>bootstrap"]
  E["5. management/<br/>scps"]

  A -->|enables RAM<br/>org-sharing| C
  A -->|OIDC provider| B
  B -->|state bucket<br/>exists| C
  B -->|state bucket<br/>exists| D
  A -.->|SCPs applied<br/>last to avoid<br/>self-locking| E
```

Rationale documented inline in `terraform-apply.yml`. Violations of this order caused real incidents (PR #8, PR #9).

---

## Cross-references

- All ADRs: [docs/decisions/](decisions/)
- Setup from zero: [Runbook 001](runbooks/001-bootstrap-aws-account.md)
- Terraform code: [terraform/environments/](../terraform/environments/)
- CI workflows: [.github/workflows/](../.github/workflows/)

## Drift policy

**When this file lies, reality wins.** If you edit Terraform code that changes one of these diagrams, update the diagram in the same PR. CI does not enforce this (yet) but PR review must.

If you find a diagram that no longer matches reality, open a PR titled `docs: fix architecture drift — <area>` and fix it. Do not ignore.
