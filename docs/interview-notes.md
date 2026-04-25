<!-- session-close-review: recruiter-facing narrative; ADR/incident/runbook counts in §2.6 must agree with footer; phase status in §2.x + §5; version table in §3 -->
# Interview Notes

A reader's guide for recruiters, hiring managers, and technical leadership reviewing this project as a portfolio artifact. Different from the rest of the repo, this document is written *about* the project rather than *inside* it — its job is to frame scope, stance, and what a conversation could productively cover.

**Time budget**:
- Recruiter / HR / hunter: read all of this doc (~10 min).
- Technical leader / architect peer: skim section 1 (stance), then jump to [`docs/decisions/`](decisions/) for the 28 ADRs and [`docs/incidents.md`](incidents.md) for the 34 postmortems.

---

## 1. Who this project is by — and what that means for the scope

Built solo by a **hands-on architect** — someone who designs cross-cutting systems AND implements them personally. Not a whiteboard-only architect. Not a ticket-slicing IC either. The stance is deliberately this combination:

- **Cross-cutting design, executed line-by-line.** Every Terraform module, every GitHub Actions workflow, every IAM policy, every runbook step, every ADR, every incident postmortem in this repo was written by the same person. No delegation, no copy-from-template, no "I designed it and handed it off to the IC team." Multi-account AWS governance, CI/CD pipelines, Kubernetes platform bootstrap, security posture, cost discipline — all implemented, not just specified.
- **Specialist depth is NOT the claim.** Algorithm-level optimization, deep IAM policy minimization, Kubernetes controller-manager internals, release-engineering of upstream open-source projects — these appear in the project because they are unavoidable, but they are handled by *following published patterns from canonical sources* with clear hand-off notes, not by original invention. When a specialist joins the team, they add depth where my breadth has reached its limit.

This split is explicit for a reason: a hands-on architect's value comes from shipping the cross-cutting system AND being technically credible to operate it. Pretending to also be a deep specialist in every area I touched would break the first technical question. Stating the boundary honestly is the senior signal; hiding it would undersell the execution and over-claim the depth simultaneously.

The project value is execution and discipline, layered together:

- **Execution**: the entire repo is working code — Terraform applies cleanly, CI applies to a live AWS organization, the EKS platform bootstraps end-to-end in one workflow dispatch. See the [Phase table in README](../README.md#phases) for what's actually deployed on `main`, not aspirations.
- 28 [Architecture Decision Records](decisions/) (including several "Design iteration" sections documenting *reversed* decisions honestly)
- 34 [incident postmortems](incidents.md) (each written after the fact in a consistent format, never softened retroactively)
- A 4-workflow CI/CD split shaped by cost profile (not template copy-paste)
- Runbooks covering both the happy path and the "here is how to debug when it breaks" diagnostic order
- A config contract that makes the whole landing zone forkable in one YAML file

---

## 2. Competency inventory

Each entry: what was built → where to look in the repo → the kind of question a reviewer might ask.

### 2.1 Multi-account AWS governance

**Built**: six accounts (`aegis-management`, `-security`, `-logarchive`, `-shared`, `-staging`, `-prod`) under an AWS Control Tower foundation, across three OUs (Security / Infrastructure / Workloads). Three custom SCPs at the org root (deny-root-user-actions, deny-iam-user-creation, deny-leave-organization). IAM Identity Center for human access; no IAM users anywhere (enforced by SCP, not policy).

**Where to look**:
- [`docs/decisions/006-account-taxonomy-and-ou-structure.md`](decisions/006-account-taxonomy-and-ou-structure.md)
- [`docs/decisions/008-landing-zone-tooling-control-tower-hybrid.md`](decisions/008-landing-zone-tooling-control-tower-hybrid.md)
- [`docs/decisions/011-account-provisioning-two-path-strategy.md`](decisions/011-account-provisioning-two-path-strategy.md)
- [`terraform/environments/management/scps/`](../terraform/environments/management/scps/)
- [`terraform/environments/management/bootstrap/sso-assignments.tf`](../terraform/environments/management/bootstrap/sso-assignments.tf)

**Likely questions**: why 6 accounts (blast-radius + segregation-of-duties, ADR-006); why Control Tower + Terraform hybrid rather than native Organizations (ADR-008 — don't reinvent the CT StackSets); how would this scale to 60 accounts (Path B / AFT pivot, code already committed but not applied per ADR-011).

### 2.2 CI/CD — cost-profile-aware workflow split

**Built**: four GitHub Actions workflows, each matched to a cost profile. Baseline layers (bootstrap, SCPs, IPAM — aggregate < $5/mo) auto-apply on merge to main with paths filters. Workload layers (network with NAT, platform with EKS — $5-10/session) require `gh workflow run` with a GitHub Environment approval gate. A mirror teardown workflow destroys in reverse order. OIDC federation throughout; zero static AWS credentials in the repo.

**Where to look**:
- [`docs/decisions/009-lifecycle-and-teardown-strategy.md`](decisions/009-lifecycle-and-teardown-strategy.md)
- [`.github/workflows/`](../.github/workflows/) — all four workflows
- [`scripts/teardown/`](../scripts/teardown/) — three teardown scripts with differentiated safety checks

**Likely questions**: why a single approval gate per workflow rather than per layer (ADR-009 + PR #38 refactor); what happens on rollback (teardown workflow as tested rollback path); why OIDC instead of IAM users (zero-static-credentials principle + Incident 8 shows awareness of OIDC subject-claim nuance).

### 2.3 Kubernetes platform bootstrap

**Built**: EKS 1.32 with `authentication_mode = API` (not aws-auth ConfigMap), IRSA OIDC provider, Karpenter v1.0.8 on Fargate handling Spot-first dynamic provisioning, AWS Load Balancer Controller with ACM TLS, and ArgoCD with an app-of-apps root `Application` pointing at a sibling `aegis-core` repo. Full stack deploys from a single Terraform apply dispatched from CI.

**Where to look**:
- [`docs/decisions/013-eks-architecture.md`](decisions/013-eks-architecture.md) — and its **"Design iteration" section** documenting the reversal of the `/32` endpoint lockdown
- [`terraform/environments/staging/platform/`](../terraform/environments/staging/platform/) — 15 `.tf` files + a Kubernetes policy JSON + README

**Likely questions**: why Karpenter and not managed node groups / Cluster Autoscaler (dynamic bin-packing and cost alignment — ADR-013 Alternatives Considered); why Karpenter runs on Fargate (chicken-and-egg bootstrap — Karpenter provisions EC2, so it can't depend on EC2 itself); why Access Entries over aws-auth ConfigMap (AWS-deprecated legacy); the `/32` vs CI-managed Helm story (Incident 12 + ADR-013 Design iteration — an honest design iteration).

### 2.4 Cross-account IPAM

**Built**: AWS IPAM (Advanced Tier) in `aegis-shared`, RAM-shared to the whole organization. Top pool 10.0.0.0/8, per-region pools. Member accounts allocate VPC CIDRs via `ipv4_ipam_pool_id` — no hand-planned CIDR math.

**Where to look**:
- [`docs/decisions/004-deployment-configuration-contract.md`](decisions/004-deployment-configuration-contract.md) — "Design gap discovered during implementation" section and "Design implications of the release lag" section
- [`terraform/environments/shared/ipam/`](../terraform/environments/shared/ipam/)
- [`docs/incidents.md`](incidents.md) Incident 7 — the 4-prerequisite discovery story

**Likely questions**: why IPAM over static CIDR allocation (enforces non-overlap at API level — ADR-004 Mode B); what are the destroy-time implications (10-20 min release lag — hard design constraint, documented).

### 2.5 Security posture

**Built**: three SCPs at org root. Customer-managed KMS keys for the cross-account state bucket (with key policy granting `kms:Decrypt` to `aws:PrincipalOrgID`), for EKS secrets envelope encryption, and for CloudWatch log groups. GitHub OIDC with subject-claim scoping (four subjects: main ref, pull_request, environment:workload-apply, environment:workload-teardown). No IAM users anywhere by design.

**Where to look**:
- [`docs/decisions/005-compliance-framework-iso-27001.md`](decisions/005-compliance-framework-iso-27001.md)
- [`terraform/environments/management/scps/`](../terraform/environments/management/scps/)
- [`terraform/environments/shared/bootstrap/kms-state.tf`](../terraform/environments/shared/bootstrap/kms-state.tf)
- [`terraform/environments/staging/bootstrap/oidc-github.tf`](../terraform/environments/staging/bootstrap/oidc-github.tf)

**Likely questions**: what is and isn't a secret in this repo ([`CLAUDE.md` "Security" section](../CLAUDE.md) lists both); how key rotation works (AWS-handled via `enable_key_rotation = true`); break-glass approach (cold root + admin bypass on branch protection).

### 2.6 Operational discipline (ADRs, incidents, runbooks)

**Built**: three layers of operational writing with explicit rules in [`CLAUDE.md`](../CLAUDE.md):
- **ADRs** — 27 in [`docs/decisions/`](decisions/), supersede-in-place style ("Design iteration" sections note evolution; ADR-018 §3 has an in-place amendment demonstrating the pattern; ADR-015 superseded by ADR-022 demonstrates the supersede-with-history pattern; ADR-027 layers onto ADR-024 as a sibling at a finer granularity)
- **Incidents** — 34 in [`docs/incidents.md`](incidents.md), append-only, standard format
- **Runbooks** — 8 in [`docs/runbooks/`](runbooks/); CLAUDE.md rule requires AI agents to read the layer's runbook before operating on it

**Where to look**:
- [`CLAUDE.md`](../CLAUDE.md) — 6 explicit "Rule: AI must..." clauses
- [`docs/decisions/`](decisions/) — 28 ADRs
- [`docs/incidents.md`](incidents.md) — 34 postmortems
- [`docs/runbooks/`](runbooks/) — 8 runbooks
- [`docs/principles/`](principles/) — 2 cross-cutting discipline docs (change-review, break-glass-apply)

**Likely questions**: show me a real incident (pick from the 32 in `docs/incidents.md` — Incidents 6, 7, 12, 18, 22, 24, 25, 26 cover the widest angle: CMK recovery, hidden cross-account prerequisites, honest design reversal, asymmetric IAM policy, belt-and-suspenders teardown architecture, Terraform concurrency edge cases, service-specific resource-policy quirks, and ArgoCD-managed-CRD bootstrap race); what does the ADR format give you that code comments don't (ADRs preserve *why* even when *what* is obvious from code); how do you keep this discipline consistent (CLAUDE.md rules + pre-commit hooks + AI reminders — not willpower).

### 2.7 Cross-repo coordination

**Built**: a durable coordination protocol between two independently-maintained repositories (`aegis-aws-landing-zone` for infrastructure, `aegis-core` for application). Standing GitHub Issues serve as the contract surface — [#54](https://github.com/BinHsu/aegis-aws-landing-zone/issues/54) documents what the platform provides; [#11](https://github.com/BinHsu/aegis-core/issues/11) documents what the application needs. Label semantics (`cross-repo`, `cross-repo/blocking`, `cross-repo/fyi`) govern urgency. Either side can open issues on the other.

**Where to look**:
- [README §Cross-repo coordination](../README.md#cross-repo-coordination)
- [CONTRIBUTING.md §Cross-repo coordination](../CONTRIBUTING.md#cross-repo-coordination)
- [`CLAUDE.md`](../CLAUDE.md) "Cross-repo coordination" section (operational rules for AI agents)
- [#54 body](https://github.com/BinHsu/aegis-aws-landing-zone/issues/54) — the live platform contract

**Likely questions**: why Issues instead of a shared config file or API contract (audit trail + async-first — agents and humans both see the same history); how do you prevent drift between the contract and reality (CLAUDE.md rule: PRs that change the platform surface must update #54 in the same PR); what happens when one side is blocked (label escalation — `cross-repo/blocking` halts planning until acknowledged).

### 2.8 Cost governance

**Built**: $30/month + $10/day AWS Budgets. Baseline layers cost < $5/mo; workload layers cost $5-10/session when running. Teardown is a first-class feature: three scripts (soft for session end, hard for project end with triple confirmation + anti-CI flag, emergency cloud-nuke for drift recovery). Karpenter NodePool has a hard 4-vCPU cluster-wide cap as a cost backstop.

**Where to look**:
- [`CLAUDE.md`](../CLAUDE.md) "Cost Guardrails" section
- [`scripts/teardown/`](../scripts/teardown/) + [`scripts/teardown/README.md`](../scripts/teardown/README.md) decision tree
- [`scripts/emergency/nuke-workload-account.sh`](../scripts/emergency/nuke-workload-account.sh)
- [`terraform/environments/staging/platform/karpenter-nodepool.tf`](../terraform/environments/staging/platform/karpenter-nodepool.tf) — `limits: { cpu: "4", memory: "16Gi" }`

**Likely questions**: what prevents a forgotten teardown (budget alerts + CLAUDE.md rule + one-command soft teardown); soft vs hard teardown (soft preserves state bucket and all non-workload resources; hard calls CloseAccount → 90-day suspension); worst-case leak (EKS + NAT + Fargate = ~$135/mo if forgotten; daily budget alert catches within 24h).

### 2.9 Methodology alignment — GitOps, DevSecOps, FinOps

This project practices all three frameworks. None are bolted on — they are load-bearing properties enforced by code, not compliance checklists filled in after the fact. The mapping below is for interviewers who want to verify the claim against specific artifacts.

**GitOps** — Git is the single source of truth for both infrastructure and workload state.

| Practice | Where it's enforced |
|---|---|
| Declarative infrastructure | All Terraform; zero imperative scripts or console clicks |
| PR-based change flow | `terraform-plan.yml` comments plan output on every PR; merge triggers apply |
| Pull-based workload deployment | ArgoCD watches `aegis-core`, auto-syncs staging ([`argocd.tf`](../terraform/environments/staging/platform/argocd.tf)) |
| Drift detection + self-heal | ArgoCD `selfHeal: true`; Checkov blocks drifted security posture at PR time |
| Environment parity via config | Single `landing-zone.yaml` drives all environments ([ADR-004](decisions/004-deployment-configuration-contract.md)) |

**DevSecOps** — security is a property of the pipeline, not a gate after it.

| Practice | Where it's enforced |
|---|---|
| Shift-left security scan | Checkov IaC scan on every PR ([`.github/workflows/checkov.yml`](../.github/workflows/checkov.yml)) |
| Guardrails before resources | SCPs deny dangerous actions org-wide before any workload runs ([`management/scps/`](../terraform/environments/management/scps/)) |
| Zero static credentials | SSO for humans, OIDC for CI, IRSA for pods; `deny-iam-user-creation` SCP enforces this at org level |
| Least-privilege CI roles | Dedicated per-function roles for aegis-core ECR push and cache access (#74); Terraform CI is separate |
| Runtime threat detection | GuardDuty EKS Runtime + Audit Log Monitoring ([`workloads/guardduty.tf`](../terraform/environments/staging/workloads/guardduty.tf)) |
| Admission control | Kyverno baseline policies: deny-privileged, deny-host-namespaces, require-limits, require-labels ([ADR-016](decisions/016-admission-control.md)) |
| Network segmentation | Default-deny NetworkPolicy in workload namespace; VPC Flow Logs to S3 |
| Supply chain | Signed commits (branch protection), GitHub Secret Scanning + push protection, Dependabot vulnerability alerts, ECR `scan_on_push` |
| Compliance alignment | ISO 27001 Annex A.8 ([ADR-005](decisions/005-compliance-framework-iso-27001.md)); change-review discipline doc ([`docs/principles/`](principles/change-review-discipline.md)) |

**FinOps** — cost is a design constraint, not a surprise on the bill.

| Practice | Where it's enforced |
|---|---|
| Cost-aware architecture | Single NAT (not three), Spot-first nodes, ACM over cert-manager, Fargate for bootstrap pods |
| Budget alerts | $10/day + $30/month AWS Budgets in management account |
| Teardown as first-class feature | Three scripts (soft/hard/emergency) + CI teardown workflow ([ADR-009](decisions/009-lifecycle-and-teardown-strategy.md)) |
| Cost-profile workflow split | Baseline layers (~free) auto-apply on merge; workload layers ($5-10/session) require manual dispatch + approval gate |
| Resource caps | Karpenter 4-vCPU cluster-wide limit as cost backstop |
| Cost visibility | Every ADR, phase spec, and PR description notes hourly/monthly cost; CLAUDE.md rule requires AI to flag cost before applying |

**Likely questions**: which of these three was the hardest to maintain (FinOps — cost discipline is a continuous judgment call, not a one-time policy; every new resource needs a "what does this cost idle?" answer before it ships); how do you prevent methodology drift (CLAUDE.md rules are the enforcement layer — they are read by both the human operator and the AI agent, and they reference specific artifacts rather than abstract principles); is this SOC 2 / PCI ready (no — [§4 Explicit scope-of-claims](#4-explicit-scope-of-claims) states this explicitly; the methodology is transferable but the audit trail is not complete).

---

## 3. Conservative-by-design — "why not the absolute newest"

This project picks the **current-stable** version of each tool rather than the absolute newest. Each choice has a reason, and the reason is the signal. Chasing bleeding-edge is not senior behavior; *choosing stable with awareness of the trade-off* is.

| Tool / feature | Chosen | Newest-available | Why conservative |
|---|---|---|---|
| Terraform | 1.14.8 | 1.14.8 | Current stable; `use_lockfile = true` needs ≥ 1.10. |
| AWS provider | `~> 5.0` | 6.x | 6.x has breaking changes around IPAM that would force a migration cycle; tracked via open Dependabot PRs for a deliberate review. |
| EKS | 1.32 | 1.33 | AWS standard support for 1.32 runs into 2027; 1.33 is too new for production stability. |
| Karpenter | v1.0.8 (chart 1.0.8) | v1.1.x | Minor bumps post-v1 still ship behavior changes; pin until release notes are verified. |
| Bottlerocket AMI | `@latest` alias | (same) | Karpenter-resolved alias follows AWS SSM parameters; automatic patch pickup on next node roll. |
| ArgoCD | chart 7.6.12 (ArgoCD 2.12.x) | 2.13.x | 2.12 is the current stable LTS branch; 2.13 ships features still in beta. |
| AWS Load Balancer Controller | chart 1.8.2 (controller v2.8.2) | 2.9.x | Controller IAM policy tracks chart version; canonical policy for 2.8.2 is in-repo at `lb-controller-policy.json`. |
| EKS IRSA | IRSA (not Pod Identity) | Pod Identity | Pod Identity is the 2023 successor; for greenfield it's the recommended path. IRSA ecosystem docs are still richer, so the project uses IRSA and tracks Pod Identity migration in the Phase 5 backlog (ADR-013 explicit). |
| Account provisioning | Path A (Service Catalog) | Path B (AFT) | AFT scales better; Path A is simpler to reason about at 2 accounts. AFT code committed in `terraform/environments/shared/aft/` but not applied (ADR-011). |

The pattern: **"I chose X not Y because Z, and the migration to Y is tracked at location W."** Every row above follows this shape.

---

## 4. Explicit scope-of-claims

Positive statements of what this project demonstrates, paired with explicit statements of what it does *not* demonstrate. The honest framing is the point; claiming everything would be a red flag.

### What is claimed

- **Cross-cutting architectural design**: composing 10+ AWS services into a working multi-account landing zone with explicit decisions (ADRs) and documented trade-offs.
- **Operational discipline**: 28 ADRs + 34 incident postmortems + 8 runbooks + 2 cross-cutting principle docs, each written to a consistent format, never softened retroactively.
- **Production-shaped patterns** — not production-*hardened* (the lab is single-operator, single-region-primary, no DR-tested, no SOC 2 audit trail). The patterns are transferable to production; the lab itself isn't production.
- **Reproducibility**: a single `config/landing-zone.yaml` + two shell scripts land the whole foundation in a fresh AWS organization. Fork-and-deploy is not a slogan here; it's tested.

### What is NOT claimed

- **IAM policy authoring as a specialty.** Both the Karpenter controller policy ([`karpenter-iam.tf`](../terraform/environments/staging/platform/karpenter-iam.tf)) and the AWS Load Balancer Controller policy ([`lb-controller-policy.json`](../terraform/environments/staging/platform/lb-controller-policy.json)) are adapted from canonical upstream sources (Karpenter's CloudFormation template; `kubernetes-sigs/aws-load-balancer-controller` v2.8.2's published policy). A deeper specialist would use the `terraform-aws-modules/eks/karpenter` sub-module and not own the Karpenter policy at all. The choice to inline was to keep the policy reviewable in one place for this project's scope; at enterprise scale, the sub-module is the right pivot.
- **Kubernetes internals as a specialty.** Enough to bootstrap a cluster, reason about Access Entries vs aws-auth ConfigMap, and wire up IRSA. Not enough to answer deep questions about CRD schema evolution, controller-manager reconciliation loops, or scheduler internals.
- **Karpenter / ArgoCD internals as a specialty.** Install + configure + diagnose connectivity; I do not claim to know what changed internally between Karpenter v0.37 → v1.0 beyond what the release notes say.
- **Algorithm-level optimization.** When a teardown takes 20 minutes due to IPAM release lag ([ADR-004 Consequences](decisions/004-deployment-configuration-contract.md)), the answer is "live with it, document it, adjust timeouts." A specialist might investigate whether there's a faster release path; that investigation is not in scope for a hands-on architect whose job is shipping the cross-cutting system.
- **Network deep-dive.** VPC design (subnets, NAT, Gateway endpoints) follows public reference architectures. Deep questions about BGP, IPv6 dual-stack, Transit Gateway attachment routing, or MTU tuning are outside the scope of this project.
- **Production observability at scale.** Phase 4b ships Grafana Cloud free tier as backend + Grafana Alloy + prometheus-operator-crds + grafana-operator in-cluster. Per-cluster Thanos / Mimir self-host and full vendor APM (Datadog) are out of scope; scaling path to Thanos-in-shared-account or AMP+AMG documented in ADR-021.
- **DR testing.** Control Tower governs two regions (eu-central-1 primary, eu-west-1 DR), but no DR failover has been tested end-to-end. The DR region is set up for future work.
- **Compliance audit readiness.** ISO 27001 alignment is the guardrail ([ADR-005](decisions/005-compliance-framework-iso-27001.md)). Phase 4c adds runtime enforcement (GuardDuty EKS for threat detection, Kyverno for admission control) but this is not a SOC 2 / PCI / HIPAA audit-ready posture. The lab demonstrates the *patterns* — baseline policies, deny-privileged, require-limits — not the completeness of a production control set.

### Positive framing for the interview

> "I'm a hands-on architect — I design cross-cutting systems and build them myself, line by line. Where a specialist's depth would exceed my breadth's value, I know where the hand-off is. When a specialist joins the team, I hand them a functional foundation with a written record of what decisions have been made, what was tried and didn't work, and what's deferred. That's the deliverable: not architecture-as-slides, not code-as-tickets, but a working system with its operational contract documented."

---

## 5. Narrative arc — the story to tell

### Phase 0 — Bootstrap (done)
AWS Control Tower landing zone + management account IAM + cold root. [Runbook 001](runbooks/001-bootstrap-aws-account.md) is the step-by-step. Incidents 1 (KMS policy), 2 (account alias), 3 (RAM + apply order) landed here.

### Phase 1 — Foundation (done)
IAM Identity Center, SSO user, permission set, cross-account IAM; Terraform state bucket with CMK in `aegis-shared`. Incident 5 (cross-account `kms:Decrypt` with `aws/s3`) landed here.

### Phase 2 — GitOps pipeline (done)
GitHub OIDC, four GitHub Actions workflows split by cost profile, Checkov + pre-commit. PRs #9-#38 span this phase. Incidents 3, 6 (CMK destroyed by CI), 8 (OIDC subject claims) landed here.

### Phase 3 — EKS + Karpenter + ArgoCD (done)
Three incremental PRs for core features (#39 EKS core, #42 Karpenter, #43 LB Controller + ArgoCD) plus a run of cold-apply hardening PRs (#44–#46, #48, #51, #53, #56, #57, #59, #62) that codified every first-apply discovery into infra-as-code so a forker's next cold apply is clean. Incidents 10–22 landed here, covering bootstrap traps, AWS-side auto-resource orphans, admission webhook races, IAM policy asymmetry, and the Karpenter-quiesce belt-and-suspenders teardown architecture (Incidents 19–22, all four layered on top of each other).

### Post-Phase-3c — ongoing ops hygiene (done 2026-04-15)
Two incidents caught during a Dependabot maintenance sweep after the Phase 3c rollout, both fixed via PRs #63 and #64: **Incident 23** — Dependabot PRs run in a separate secret namespace from Actions, so `scripts/configure-github.sh` now populates both; **Incident 24** — S3 native state locking is strictly FCFS with no queue, default `-lock-timeout=0` stampedes under bulk rebase, `terraform-plan.yml` now specifies `-lock-timeout=10m`. Same session also enabled GitHub Secret Scanning + push protection + Dependabot vulnerability alerts (free on public repos; directly validate the "zero static credentials by design" stance) and bumped the AWS Terraform provider v5.100 → v6.40 across all six Terraservices with baseline apply success on every leg.

### Phase 4 — Observability + cluster security (done 2026-04-17)
Three sub-phases shipped in PRs #67–#69: **4a'** (docking station — `aegis` namespace, IRSA skeleton, default-deny NetworkPolicy, ADR-017); **4b** (kube-prometheus-stack via ArgoCD with deprecated-API alert rule, VPC Flow Logs to S3 in Parquet, ADR-015) (observability backend reversed 2026-04-21 per ADR-022; see ADR-022 §Context for rationale); **4c** (GuardDuty EKS Runtime + Audit Log Monitoring, Kyverno admission controller with 4 baseline policies in Audit mode, ADR-016). Cross-repo coordination protocol ([#54](https://github.com/BinHsu/aegis-aws-landing-zone/issues/54), [#11](https://github.com/BinHsu/aegis-core/issues/11)) exercised live during the session. Phase 4a'' (actual workload deployment) gates on aegis-core shipping OCI images.

### Phase 5 — Service mesh + per-pod TLS (not started)
cert-manager, service mesh mTLS, private endpoints, EKS Pod Identity migration.

---

## 6. Where to go for the deep dive

This doc is frame-level. For the actual substance:

| Interest | Open |
|---|---|
| "Walk me through the architectural decisions" | [`docs/decisions/`](decisions/) — 28 ADRs |
| "Show me real failures and what you learned" | [`docs/incidents.md`](incidents.md) — 34 postmortems |
| "How do I reproduce this?" | [`docs/runbooks/001-bootstrap-aws-account.md`](runbooks/001-bootstrap-aws-account.md) |
| "How would an AI agent work on this?" | [`CLAUDE.md`](../CLAUDE.md) |
| "What does the config contract look like?" | [`config/landing-zone.example.yaml`](../config/landing-zone.example.yaml) + [`config/schema.json`](../config/schema.json) + [ADR-004](decisions/004-deployment-configuration-contract.md) |
| "Most interesting Terraform surface" | [`terraform/environments/staging/platform/`](../terraform/environments/staging/platform/) — EKS platform, 15 `.tf` files |

---

*Last updated: 2026-04-24 — ldz #101 closed: ACM cert for `aegis-api.staging.binhsu.org` materialized via baseline dispatch (PRs #143 + #145 closed the CI apply gap for `staging/edge/`). ADR-027 added (intra-environment Terraservice layer sharding discipline; sibling of ADR-024 at finer granularity). ADR-026 promoted Partially Accepted → Accepted after Cognito User Pool went live end-to-end. Qdrant Cloud scaffold shipped per aegis-core ldz #141 (SSM + ExternalSecret, mirrors the team-webhooks pattern). Cold-apply gate now fully cleared — next session candidate is joint big-bang validation. ADR count 26→27; runbook count unchanged at 8; incidents unchanged at 32.*

*Previous: 2026-04-21 (PM) — ADR-022 implementation shipped as 4 PRs (platform-layer ESO + prometheus-operator-crds + kube-state-metrics + Grafana Alloy; new `staging/observability/` peer layer with grafana-operator + GC tokens; kube-prometheus-stack removed from workloads; teardown workflow CRD pre-delete). Observability backend now lives in Grafana Cloud; in-cluster Prometheus + Grafana are gone. ADR count unchanged at 24; incidents unchanged at 32 (code-only session, no cold-apply).*

*Previous: 2026-04-21 (AM) — Observability backend reversed: ADR-015 (kube-prometheus-stack) superseded by ADR-022 (Grafana Cloud free tier + Alloy + grafana-operator) + ADR-023 (backend-agnostic responsibility model). ADR-024 added (landing-zone repo topology). Runbook 006 added for Grafana Cloud onboarding. ADR-021 rung 1 redefined. ADR count 21 → 24.*

*Earlier: 2026-04-20 — Multi-region slot pattern now covers all three workload-tier layers (network + platform + workloads); ADR-015 amended (Discovery contract for PrometheusRule / ServiceMonitor / Grafana dashboard discovery, fixing fact drift on Application CRD ownership); ADR-018 §3 amended (K=2 ceiling guard now in 3 layers, not 2). ADR count unchanged at 19; only amendments.*

*Previous: 2026-04-19 — Multi-region EKS design ratified (ADR-018); `docs/improvements/` directory established for productionization roadmap (state backend cross-account replica, workload multi-region DR); ADR count 17→18.*

*Previous: 2026-04-17 — Phase 4 shipped (4a' docking station, 4b observability, 4c cluster security); cross-repo coordination documented for forkers; ADR count 13→17.*
