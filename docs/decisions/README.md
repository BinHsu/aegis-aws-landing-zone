<!-- session-close-review: index table + statuses match the actual ADR files; reading orders still point at ADRs that exist -->

# Architecture Decision Records

This directory holds the Architecture Decision Records (ADRs) for the AWS
landing zone. An ADR captures a significant design choice — account placement,
tooling, multi-region strategy, security posture — at the moment it was made,
together with the alternatives that were rejected and the trade-offs accepted.

**Conventions**

- **Numbering**: sequential, zero-padded (`001`, `002`, …). Never reused.
- **Filename**: `NNN-title.md`.
- **Status**: `Accepted` | `Superseded by NNN` | `Deprecated`. A superseded ADR
  is *not* deleted — it stays as a historical record; only its `Status` line
  changes. Amendments are annotated inline at the top of the affected ADR.
- **Rule**: AI agents and contributors must check this directory before
  proposing architecture. If a decision is already recorded, follow it; if you
  believe it should change, discuss first — do not silently override.

Low-contention choices (a default that nobody argued about) do **not** get an
ADR — they live in code comments or in `CLAUDE.md`. An ADR is for decisions
where alternatives were genuinely weighed.

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [001](001-landing-zone-scope-boundary.md) | Landing Zone Scope Boundary | Accepted |
| [002](002-region-and-availability-zone-strategy.md) | Region and Availability Zone Strategy | Accepted |
| [003](003-terraform-backend-bootstrap.md) | Terraform Backend Bootstrap and State Layout | Accepted |
| [004](004-deployment-configuration-contract.md) | Deployment Configuration Contract | Accepted |
| [005](005-compliance-framework-iso-27001.md) | Compliance Framework — ISO 27001 Mapping | Accepted |
| [006](006-account-taxonomy-and-ou-structure.md) | Account Taxonomy and OU Structure | Accepted |
| [007](007-infra-app-repository-split.md) | Infrastructure / Application Repository Split | Accepted |
| [008](008-landing-zone-tooling-control-tower-hybrid.md) | Landing Zone Tooling — Control Tower + Terraform Hybrid | Accepted |
| [009](009-lifecycle-and-teardown-strategy.md) | Lifecycle and Teardown Strategy | Accepted |
| [010](010-shared-account-bootstrap-sequence.md) | Shared Account Bootstrap Sequence | Accepted |
| [011](011-account-provisioning-two-path-strategy.md) | Account Provisioning Strategy — Two-Path Design | Accepted |
| [012](012-vpc-topology-and-egress-strategy.md) | VPC Topology and Egress Strategy | Accepted |
| [013](013-eks-architecture.md) | EKS Architecture | Accepted |
| [014](014-alb-session-affinity.md) | ALB Session Affinity for gRPC Workloads | Accepted |
| [015](015-observability-tooling.md) | Observability Tooling | **Superseded by 022** |
| [016](016-admission-control.md) | Admission Control: Kyverno | Accepted (amended) |
| [017](017-workload-namespace-and-rbac-model.md) | Workload Namespace and RBAC Model | Accepted |
| [018](018-multi-region-eks-design.md) | Multi-region EKS Design | **Superseded by 032** (§1/§2/§5–§7 still authoritative) |
| [019](019-frontend-serving-strategy.md) | Frontend Serving Strategy — S3 + CloudFront | Accepted |
| [020](020-fis-dr-drill.md) | Fault Injection Simulator (FIS) for DR Drills | Accepted (amended) |
| [021](021-observability-scaling-path.md) | Observability Scaling Path | Accepted (amended) |
| [022](022-observability-backend-grafana-cloud.md) | Observability Backend: Grafana Cloud Free Tier | Accepted (supersedes 015) |
| [023](023-observability-responsibility-model.md) | Observability Responsibility Model | Accepted |
| [024](024-landing-zone-repo-topology.md) | Landing-zone Terraform Repo Topology | Accepted |
| [025](025-qdrant-backend-cloud-free-tier.md) | Qdrant Backend — Cloud Free Tier | Accepted |
| [026](026-cognito-auth-user-pool.md) | Cognito User Pool — Cloud-mode Auth | Accepted |
| [027](027-intra-environment-layer-sharding.md) | Intra-environment Terraservice Layer Sharding Discipline | Accepted |
| [028](028-persistent-saas-credential-isolation.md) | Persistent SaaS-credential Isolation | Accepted |
| [029](029-iam-permission-scope-down.md) | IAM Permission Scope-Down for `github-actions-terraform` | Accepted |
| [030](030-tier-2b-permission-boundary-hardening.md) | Tier 2B Permission Boundary Hardening | Accepted |
| [031](031-tier-3-detective-controls.md) | Tier 3 Detective Controls | Accepted |
| [032](032-external-orchestration-multi-region.md) | External Orchestration for Multi-region EKS | Accepted (supersedes 018 §3–§4) |
| [033](033-landing-zone-scope-correction-account-fabric.md) | Landing-zone Scope Correction — Account Fabric | Accepted (supersedes 001 scope-list; phased) |

> Filenames in the table are the conventional `NNN-title.md` form. If a link
> 404s, the on-disk title slug differs slightly — the number is authoritative.

## Reading orders by audience

You do not need to read 33 ADRs front to back. Pick the path for why you are
here. Each list is ordered so the argument builds on itself.

### Senior platform / infrastructure reviewer

Understand the shape of the landing zone and why it is shaped that way.

`001` → `033` → `006` → `008` → `011` → `003` → `004` → `024` → `007` → `002` → `012` → `013` → `018` → `032` → `027`

Scope boundary first (what this repo does and does not own) — read `001`
immediately with `033`, which corrects that scope down to the account fabric and
reclassifies EKS/ArgoCD/observability as an extractable Platform tier. Then the
account/OU taxonomy, the Control-Tower-plus-Terraform tooling split, and how
accounts are provisioned. State layout and the config contract explain how the
code is parameterised; the repo-topology and infra/app-split ADRs explain the
tier model. The tail (`002`–`027`) is the workload substrate: regions, VPC, EKS,
multi-region, and the layer-sharding discipline.

### Reliability / DR reviewer

Understand the failure model and how recovery is proven.

`002` → `009` → `018` → `032` → `020` → `003` → `021` → `022` → `023`

Region/AZ strategy and the lifecycle/teardown model set the baseline; the
multi-region design and the FIS DR-drill ADR are the core. State backend
explains recovery of the control plane itself; the three observability ADRs
explain how a drill is *observed* (the dashboard is the evidence).

### Security reviewer

Understand the guardrails and the blast-radius controls.

`001` → `005` → `006` → `008` → `016` → `017` → `029` → `030` → `031` → `028` → `011` → `026`

Scope and the ISO 27001 mapping frame the compliance intent; account taxonomy
and tooling show where SCP guardrails sit. Kyverno and the namespace/RBAC model
are the in-cluster controls. `029`–`031` are the IAM scope-down ladder
(permission scope-down → permission boundary → detective controls); `028`
covers SaaS-credential isolation. `011` and `026` cover account provisioning
and human/workload authentication.

### Forker / new contributor

The minimum to understand the repo before touching anything.

`001` → `033` → `004` → `024` → `008` → `009`

What the repo is for and how its scope was corrected (`033` descopes it to the
account fabric), how config drives it, how the one repo is isolated internally,
what tooling it assumes, and the lifecycle/teardown rules that keep a fork from
running up a bill.
