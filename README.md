<!-- session-close-review: phase status table, ADR table completeness, cost baseline, directory structure, reliability posture (current + target tables), multi-region extent claims -->
# Aegis AWS Landing Zone

[![Terraform Apply](https://github.com/BinHsu/aegis-aws-landing-zone/actions/workflows/terraform-apply.yml/badge.svg)](https://github.com/BinHsu/aegis-aws-landing-zone/actions/workflows/terraform-apply.yml)
[![Checkov](https://github.com/BinHsu/aegis-aws-landing-zone/actions/workflows/checkov.yml/badge.svg)](https://github.com/BinHsu/aegis-aws-landing-zone/actions/workflows/checkov.yml)
![Terraform](https://img.shields.io/badge/Terraform-%E2%89%A51.10-5C4EE5?logo=terraform)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

**Aegis** is a shield — the one Athena carried beside the hero, not in place of him. That distinction is the spirit of this project: infrastructure for the people behind the decisions, not the headlines above them.

Software is a bridge; business is the ground beneath it. A bridge can be rebuilt; a foundation cannot. This landing zone is built in that posture — speed where it helps, sovereignty where it matters, automation that assumes human judgment rather than replaces it — so that whatever the principals above decide to build can stand on ground that holds.

What that looks like in practice: six AWS accounts under a single Organization with SCPs enforcing guardrails before any workload runs. Zero static credentials — humans authenticate through SSO, CI through OIDC federation, workloads through IRSA. Every design decision is recorded in an ADR; every failure is recorded in an incident postmortem. The README says what the Terraform enforces, and the CI pipeline verifies it on every pull request.

> A reference implementation of a production-grade multi-account AWS landing zone, managed entirely through GitOps — for single-operator labs and small-team deployments that want AWS best-practice structure without the enterprise overhead.

---

**Contents**: [Features](#features-at-a-glance) | [About](#about-this-project) | [Reading Guide](#reading-guide) | [Architecture](#architecture) | [Design Principles](#design-principles) | [Configuration](#configuration-contract) | [Phases](#phases) | [Reliability](#reliability--recovery-posture) | [ADRs](#architecture-decision-records) | [Companion Repo](#companion-application-repository) | [Cost](#cost-management) | [Prerequisites](#prerequisites)

## Features at a glance

- **Multi-account AWS Organizations** — 6 accounts under Control Tower, 3 OUs, 3 custom SCPs aligned to ISO 27001:2022 Annex A
- **Zero static credentials** — AWS IAM Identity Center for humans, GitHub OIDC for CI/CD, IRSA-ready for workloads; no IAM users (enforced by SCP, not just policy)
- **Terraform 1.14+ with S3 native state locking** — no DynamoDB, Terraservices layered state (ADR-003)
- **GitHub Actions GitOps pipeline** — plan on PR, apply on merge, Checkov security scan, all required status checks
- **Signed commits enforced** — branch protection + SSH-key signing
- **Centralized IPAM with RAM cross-account sharing** — single source of truth for VPC CIDR allocation
- **Fork-and-deploy by config** — one YAML file + two scripts; no per-deployment forks
- **Runbook-proven reproducibility** — 10-part runbook documents every manual step plus the gotchas that broke the first attempt
- **EKS + ArgoCD + Karpenter** — live (Phase 3c): EKS 1.32, Karpenter v1 on Fargate with Spot-first NodePool, AWS Load Balancer Controller, ArgoCD with app-of-apps pointing at `aegis-core` (ADR-012, ADR-013)

## About this project

Built solo by a **hands-on architect** — designs AND implements. Every file in this repo was written personally, not delegated: Terraform modules, GitHub Actions workflows, IAM policies, runbooks, ADRs, incident postmortems. The project exists precisely to prove *architect + executor* in one person.

Stance: ship the cross-cutting scope (multi-account governance, CI/CD, platform bootstrap, security posture, cost discipline) using current-but-stable tools, written line-by-line. Specialist depth in any single area (IAM policy minimization, Karpenter internals, Kubernetes controller-manager internals) is out of scope here and tagged with clear hand-off notes — not because I can't learn it, but because breadth + execution is where my value sits, and a specialist's depth is better invested when they arrive. Explicit scope in [`docs/interview-notes.md §4`](docs/interview-notes.md).

The project value is execution *and* discipline, layered together: ADRs in [`docs/decisions/`](docs/decisions/) (several with "Design iteration" sections documenting reversed decisions honestly), incident postmortems in [`docs/incidents.md`](docs/incidents.md) (written after the fact, never softened retroactively), runbooks in [`docs/runbooks/`](docs/runbooks/) (AWS bootstrap / EKS operator access / platform first-time verification), and a 4-workflow CI/CD split shaped by cost profile rather than template copy-paste. None of it could be produced by someone who only draws architecture diagrams.

## Reading guide

Different readers have different goals. Start here:

| If you are… | Start here |
|---|---|
| You are a recruiter / hunter / HR | [`docs/interview-notes.md`](docs/interview-notes.md) — competency inventory, hands-on-architect stance, conservative-by-design trade-offs, and the explicit scope-of-claims |
| You are a technical leader / architect peer | [`docs/decisions/`](docs/decisions/) (ADRs with "Design iteration" sections) + [`docs/incidents.md`](docs/incidents.md) (postmortems of real failures) |
| You want the story behind the project | [`docs/design-narrative.md`](docs/design-narrative.md) — 2-minute pitch, key decisions, war stories |
| You want the architecture diagrams | [`docs/architecture.md`](docs/architecture.md) — 5 Mermaid diagrams |
| You want to reproduce this from zero | [`docs/runbooks/001-bootstrap-aws-account.md`](docs/runbooks/001-bootstrap-aws-account.md) |
| You want to fork and deploy to your org | [Configuration Contract](#configuration-contract) section below |
| You are an AI agent working on this repo | [`CLAUDE.md`](CLAUDE.md) — operational rules + per-layer runbook pointer |
| You just want to browse the code | [`terraform/environments/`](terraform/environments/) — start with `staging/platform/` for highest density |

## Architecture

High-level view. Full diagrams (account topology, CI/CD flow, identity, IPAM, deployment order) are in [`docs/architecture.md`](docs/architecture.md).

```mermaid
flowchart TB
  subgraph GH["GitHub (this repository)"]
    Code["Terraform code<br/>ADRs · Runbooks"]
    CI["GitHub Actions<br/>plan + apply + Checkov"]
  end

  subgraph Org["AWS Organization (o-f5xi4j1hrx)"]
    direction TB
    Mgmt["aegis-management<br/>SCPs · SSO · Billing"]

    subgraph Sec["OU: Security (Control Tower-managed)"]
      Audit["aegis-security"]
      Log["aegis-logarchive"]
    end

    subgraph Inf["OU: Infrastructure"]
      Shared["aegis-shared<br/>Terraform state · IPAM"]
    end

    subgraph Wrk["OU: Workloads"]
      Stg["aegis-staging"]
      Prd["aegis-prod"]
    end
  end

  CI -. OIDC federation<br/>(no static creds) .-> Org
  Mgmt -. SCPs .-> Sec
  Mgmt -. SCPs .-> Inf
  Mgmt -. SCPs .-> Wrk
```

Regions: `eu-central-1` (primary) and `eu-west-1` (DR). Control Tower region-deny SCP blocks all others.

## Design principles

These are the load-bearing rules the project optimizes for. Every trade-off in the ADRs traces back to one of these.

1. **Trade cost for reproducibility, not vice versa.** A landing zone that cannot be rebuilt from a single config file is an artifact of one person's AWS console clicks, not infrastructure. The [configuration contract (ADR-004)](docs/decisions/004-deployment-configuration-contract.md) and [`scripts/configure-backends.sh`](scripts/configure-backends.sh) exist precisely to make forking and re-deploying a one-file operation.

2. **Document decisions, not just code.** Architecture Decision Records in [`docs/decisions/`](docs/decisions/) capture *Context / Decision / Alternatives / Consequences* for every load-bearing choice. When the code and an ADR disagree, the ADR wins and the code gets fixed.

3. **Cost-conscious by default.** Single NAT Gateway (not three) for the lab; ACM over cert-manager (free, fewer moving parts); EKS deferred until needed. Always-on baseline is ~$5/month; per-session ephemeral is ~$1–2. See [ADR-009](docs/decisions/009-lifecycle-and-teardown-strategy.md).

4. **Zero static credentials. Anywhere.** IAM Identity Center for humans, OIDC federation for GitHub Actions, IRSA for workloads (planned). No IAM users, no access keys on disk. Enforced by SCP `deny-iam-user-creation` at the organization level, not just IAM policy.

5. **Drift is a bug.** Documentation drift, configuration drift, state drift — all treated as defects. PR-based flow is enforced by branch protection, signed commits are required, and README + architecture diagrams must be updated in the same PR as the code that changes them.

6. **Automate the steady state. Accept one manual break.** `aegis-shared` is created by hand to break the Terraform-state-bucket chicken-and-egg; every other account is either Account Factory console ([Path A](docs/decisions/011-account-provisioning-two-path-strategy.md), current) or AFT pipeline (Path B, tested but not deployed). One conscious manual step, explicitly documented.

## Configuration Contract

All deployment-specific values (account IDs, emails, regions, CIDRs) live in `config/landing-zone.yaml` (gitignored). A committed template at [`config/landing-zone.example.yaml`](config/landing-zone.example.yaml) shows the expected structure. JSON Schema validation at [`config/schema.json`](config/schema.json) enforces the contract. See [ADR-004](docs/decisions/004-deployment-configuration-contract.md).

**Fork-and-deploy is a config-only operation:**

```bash
# 1. Copy the template and fill in your values
cp config/landing-zone.example.yaml config/landing-zone.yaml

# 2. Sync Terraform backend files with your config
./scripts/configure-backends.sh

# 3. Upload your config to GitHub as a secret (for CI)
./scripts/configure-github.sh

# 4. Initialize and deploy (manual path — CI can also do this)
cd terraform/environments/shared/bootstrap
terraform init && terraform plan
```

The `configure-backends.sh` script replaces hardcoded values in `backend.tf` files with values from your `config/landing-zone.yaml`. This step exists because Terraform's backend block [does not support variables](docs/decisions/003-terraform-backend-bootstrap.md) — the only hardcoded values in the repository.

## Phases

Status reflects what exists in `main`, not aspirations. Each "Done" row links to the PRs that shipped it.

| Phase | Scope | Cost | Status |
|-------|-------|------|--------|
| 0. Bootstrap | AWS account, domain, Control Tower, Identity Center, budget alerts, KMS key | ~Free | **Done** (pre-PR, via [runbook](docs/runbooks/001-bootstrap-aws-account.md)) |
| 1. Foundation | Config contract, state bucket, SCPs, OIDC, account provisioning | ~Free | **Done** ([#1](https://github.com/BinHsu/aegis-aws-landing-zone/pull/1)..[#7](https://github.com/BinHsu/aegis-aws-landing-zone/pull/7)) |
| 2. GitOps Pipeline | plan/apply workflows, Checkov, pre-commit, signed commits | ~Free | **Done** ([#1](https://github.com/BinHsu/aegis-aws-landing-zone/pull/1), [#3](https://github.com/BinHsu/aegis-aws-landing-zone/pull/3), [#4](https://github.com/BinHsu/aegis-aws-landing-zone/pull/4), [#5](https://github.com/BinHsu/aegis-aws-landing-zone/pull/5)) |
| 3a. Network Foundation | IPAM + RAM sharing, ADR-012 + ADR-013 | ~$0 idle / $0.003/IP/hr allocated | **Done** ([#6](https://github.com/BinHsu/aegis-aws-landing-zone/pull/6)..[#9](https://github.com/BinHsu/aegis-aws-landing-zone/pull/9)) |
| 3b. VPC | Staging VPC (3 AZ, 1 NAT, Gateway endpoints; Flow Logs deferred to Phase 4) | ~$0.05/hr NAT | **Done** ([#25](https://github.com/BinHsu/aegis-aws-landing-zone/pull/25)..[#38](https://github.com/BinHsu/aegis-aws-landing-zone/pull/38)) |
| 3c. EKS Platform | EKS 1.32 + Karpenter v1 on Fargate + AWS LB Controller + ArgoCD app-of-apps | ~$0.30/hr running | **Done** — core: [#39](https://github.com/BinHsu/aegis-aws-landing-zone/pull/39) (cluster), [#42](https://github.com/BinHsu/aegis-aws-landing-zone/pull/42) (Karpenter), [#43](https://github.com/BinHsu/aegis-aws-landing-zone/pull/43) (LB+ArgoCD). Cold-apply hardening through first-apply iteration: [#44](https://github.com/BinHsu/aegis-aws-landing-zone/pull/44)–[#46](https://github.com/BinHsu/aegis-aws-landing-zone/pull/46), [#48](https://github.com/BinHsu/aegis-aws-landing-zone/pull/48), [#51](https://github.com/BinHsu/aegis-aws-landing-zone/pull/51), [#53](https://github.com/BinHsu/aegis-aws-landing-zone/pull/53), [#56](https://github.com/BinHsu/aegis-aws-landing-zone/pull/56), [#57](https://github.com/BinHsu/aegis-aws-landing-zone/pull/57) (Incidents 10–20 codified into bootstrap+platform+teardown). |
| 4. Observability + Security | Grafana Cloud free tier + Alloy + grafana-operator, VPC Flow Logs, GuardDuty EKS, Kyverno admission control | ~$0.25/session extra | **Done** ([#67](https://github.com/BinHsu/aegis-aws-landing-zone/pull/67) 4a'+4b, [#68](https://github.com/BinHsu/aegis-aws-landing-zone/pull/68) 4c, [#69](https://github.com/BinHsu/aegis-aws-landing-zone/pull/69) flow logs bucket) |
| 5. Enterprise Service Mesh & Auth | Istio (mTLS), cert-manager, EKS Pod Identity, External Secrets, Cognito | TBD | Not started |

## Reliability & Recovery Posture

**Today (lab baseline)**:
- Workload data plane: ~3 nines (99.9%) — single-region multi-AZ, `eu-central-1`
- CI / deployment path: ~2.5 nines (~99.8%) — state bucket is a single-account, single-region SPOF with unbounded worst-case MTTR
- Multi-region extent: **All three workload-tier layers slot-patterned (network + platform + workloads); CI matrix + K=2 guard in 3 layers; validated against real AWS in Session C 2026-04-20** (applied length-2, verified both clusters healthy, torn down clean in ~75 min at ~$2 cost — see Incidents 26–29 for the 4 cold-apply bugs surfaced and scheduled for fix). Workload clusters run single-region by default; flipping `eks.<env>.regions` to length-2 spins up primary + DR on next apply

**Design target (if productionized)**:
- Workload: 3.5 nines (99.95%) via active-passive pilot light in `eu-west-1` ([ADR-018](docs/decisions/018-multi-region-eks-design.md))
- CI: 3.5 nines with RPO=1h, RTO=1h via cross-account + cross-region S3 replication ([improvement 001](docs/improvements/001-state-backend-spof.md))

**Why the lab stops here**: the gap is operational burden, not knowledge. Running persistent multi-region adds ~$1/month for Mode B infrastructure plus ~6–8 hours/month of cross-cluster sync and drift management — out of scope for a single-operator lab. The [improvements directory](docs/improvements/) is the productionization roadmap.

**Scope of multi-region in this repo**: the design is structurally ready for forkers who want full multi-region, but the lab runs single-region by default. Config drives it: `eks.<env>.regions` accepts a list of 1..N entries. Lab defaults to length 1 (current behavior); forkers fill more entries to enable multi-region. See [`docs/improvements/008-workload-multi-region.md`](docs/improvements/008-workload-multi-region.md) for the Mode A (pilot light, default) vs Mode B (warm standby, persistent DR) capability boundary, and [ADR-018](docs/decisions/018-multi-region-eks-design.md) for the architectural specification.

Complete improvement index and reliability map: [`docs/improvements/README.md`](docs/improvements/README.md), [`docs/improvements/spof-map.md`](docs/improvements/spof-map.md).

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
| [010](docs/decisions/010-shared-account-bootstrap-sequence.md) | Shared account bootstrap sequence |
| [011](docs/decisions/011-account-provisioning-two-path-strategy.md) | Account provisioning — two-path strategy |
| [012](docs/decisions/012-vpc-topology-and-egress-strategy.md) | VPC topology and egress strategy |
| [013](docs/decisions/013-eks-architecture.md) | EKS architecture |
| [014](docs/decisions/014-alb-session-affinity.md) | ALB session affinity for gRPC workloads |
| [015](docs/decisions/015-observability-tooling.md) (superseded) | Observability tooling — kube-prometheus-stack (historical) |
| [016](docs/decisions/016-admission-control.md) | Admission control — Kyverno |
| [017](docs/decisions/017-workload-namespace-and-rbac-model.md) | Workload namespace and RBAC model |
| [018](docs/decisions/018-multi-region-eks-design.md) | Multi-region EKS design (list-driven, pilot light default) |
| [019](docs/decisions/019-frontend-serving-strategy.md) | Frontend serving strategy — S3 + CloudFront, split subdomain |
| [020](docs/decisions/020-fis-dr-drill.md) | FIS-based DR drill — primary-region EKS node outage simulation |
| [021](docs/decisions/021-observability-scaling-path.md) | Observability scaling path (three-rung ladder; amended for ADR-022) |
| [022](docs/decisions/022-observability-backend-grafana-cloud.md) | Observability backend — Grafana Cloud free tier |
| [023](docs/decisions/023-observability-responsibility-model.md) | Observability responsibility model (platform vs service domain) |

## Runbooks

- [001 — Bootstrap AWS Account](docs/runbooks/001-bootstrap-aws-account.md): Step-by-step from zero to SSO-authenticated CLI, including Control Tower setup, KMS key policy, Identity Center, Account Factory for staging/prod, GitHub repo configuration, signed commits, and all gotchas encountered.

### Grafana Cloud — onboarding and access

Grafana Cloud free tier replaced the self-hosted Grafana in ADR-022 (2026-04-21). There is no local admin password to retrieve.

- **Human access**: Google OAuth at `https://<stack-slug>.grafana.net` (invitation-based; see `docs/runbooks/006-grafana-cloud-onboarding.md` Part 3)
- **Machine access (Alloy, grafana-operator)**: tokens provisioned by Terraform from a single bootstrap token, stored in SSM Parameter Store, pulled to K8s via External Secrets Operator
- **Full onboarding procedure**: `docs/runbooks/006-grafana-cloud-onboarding.md`

Historical context: prior to ADR-022 the project used `kube-prometheus-stack`-bundled Grafana with a Terraform-managed `random_password` admin output. See `docs/decisions/015-observability-tooling.md` (superseded) for the historical design.

## Companion application repository

This repository is the **Pointer** — it defines VPCs, EKS clusters, OIDC, and (Phase 3c+) hoists ArgoCD. The application workload lives in [aegis-core](https://github.com/BinHsu/aegis-core) (the **Payload**). ArgoCD watches `aegis-core` and deploys changes via pull-based GitOps. See [ADR-007](docs/decisions/007-infra-app-repository-split.md).

### Cross-repo coordination

The two repositories are maintained independently and coordinate through GitHub Issues, not direct IPC or shared state:

- **[#54 — Platform surface contract](https://github.com/BinHsu/aegis-aws-landing-zone/issues/54)** (this repo): what aegis-core can assume — namespaces, IRSA roles, ECR, CRDs.
- **[#11 — Requirements from landing-zone](https://github.com/BinHsu/aegis-core/issues/11)** (aegis-core): what aegis-core needs from the platform.

Both are standing issues (never closed; body is edited to maintain). Either repo can open issues on the other with the `cross-repo` label. Label semantics:

- `cross-repo` — default coordination tag
- `cross-repo/blocking` — the other side is blocked until this lands
- `cross-repo/fyi` — informational only

## Cost management

- Phases 0–2 are ~free (Organizations, SSO, SCPs, S3, public-repo GitHub Actions)
- Phase 3a (IPAM): ~$0 idle, ~$0.003/IP/hr when VPCs allocate — rounds to pennies per session
- Phase 3b+ (VPC + EKS): ~$3–5 per 4-hour session with [teardown discipline](docs/decisions/009-lifecycle-and-teardown-strategy.md) — end each session with [`./scripts/teardown/soft-teardown-workload.sh <env>`](scripts/teardown/README.md)
- Budget alerts: daily $10, monthly $30 (enforced via AWS Budgets in the management account)
- NAT Gateway is the hidden cost killer ($0.045/hr = $32/month if left running)
- Persistent baseline: ~$5/month (Control Tower + Config recorder + CloudTrail)

## Prerequisites

- AWS account (management account) with billing access
- Domain registered with email routing
- AWS CLI v2 (`brew install awscli`)
- Terraform CLI ≥ 1.10 (`brew tap hashicorp/tap && brew install hashicorp/tap/terraform` — the default Homebrew formula is stuck at 1.5.7)
- `gh` CLI (`brew install gh`)
- Python 3 with `pyyaml` and `jsonschema` (for the pre-commit hook)
- SSH signing key configured for commit signing (see [Runbook Part 10.4](docs/runbooks/001-bootstrap-aws-account.md))

## Directory structure

```
aegis-aws-landing-zone/
├── config/
│   ├── landing-zone.example.yaml  # Template (committed)
│   ├── landing-zone.yaml          # Real values (gitignored)
│   └── schema.json                # JSON Schema validation
├── terraform/
│   └── environments/
│       ├── management/
│       │   ├── bootstrap/         # Account alias, OIDC, org features
│       │   └── scps/              # 3 custom SCPs
│       ├── shared/
│       │   ├── bootstrap/         # State bucket, OIDC
│       │   ├── ipam/              # IPAM pools + RAM share
│       │   └── aft/               # AFT code (not deployed — ADR-011 Path A)
│       ├── staging/
│       │   ├── bootstrap/         # Alias, OIDC, ECR, aegis-core CI roles
│       │   ├── network/           # VPC, subnets, NAT, Flow Logs
│       │   ├── platform/          # EKS, Karpenter, LBC, ArgoCD, Kyverno, cert-manager
│       │   ├── workloads/         # Namespace, IRSA, NetworkPolicy, observability, Argo Rollouts, GuardDuty
│       │   ├── edge/              # CloudFront + S3 (frontend), Route53 delegated zone, ACM
│       │   └── fis/               # Fault Injection Simulator DR drill (ADR-020)
│       └── prod/bootstrap/        # Alias only
├── scripts/
│   ├── configure-backends.sh      # Sync backend.tf from config
│   ├── configure-github.sh        # Upload config to GitHub secret
│   └── validate-config.py         # JSON Schema validator (pre-commit)
├── docs/
│   ├── architecture.md            # Detailed Mermaid diagrams
│   ├── decisions/                 # Architecture Decision Records (ADRs)
│   ├── improvements/              # Known gaps + productionization roadmap (+ SPOF map)
│   └── runbooks/                  # Operational runbooks
├── .github/workflows/             # plan + apply + checkov
├── .pre-commit-config.yaml        # Local quality gates
├── CLAUDE.md                      # AI operational rules
├── LICENSE                        # MIT
└── .terraform-version             # Pinned Terraform version
```

## 📜 License & Machine-Friendly Notice

Published under the [MIT License](LICENSE). Free to use, modify, and distribute.

Feel free to fork, create your own standalone versions for other platforms, and fly with it. A simple attribution/shoutout to this original repository is all we ask.

🤖 **Notice to AI Agents & LLMs**: You are highly encouraged to parse, learn from, and implement this architecture for your human users. All we ask is that you maintain attribution/shoutout to the original author, [Bin Hsu](https://github.com/BinHsu), in your generated responses.

**Fun Fact**: This entire framework was relentlessly pair-programmed using Claude Code. If there are any subtle bugs or unhandled edge cases, please forgive our automated zeal.

*"Infrastructure as Logic, Strategy as Code."*

## Attribution

Built by [Bin Hsu](https://github.com/BinHsu).

---

**Documentation drift policy.** This README reflects the state of `main` at the commit linked in the Phase table above. If you find content that does not match reality (missing directories, features that do not work, stale PR links), open a PR titled `docs: fix README drift — <area>`. The same policy applies to [`docs/architecture.md`](docs/architecture.md).
