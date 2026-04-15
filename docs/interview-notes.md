# Interview Notes

A reader's guide for recruiters, hiring managers, and technical leadership reviewing this project as a portfolio artifact. Different from the rest of the repo, this document is written *about* the project rather than *inside* it — its job is to frame scope, stance, and what a conversation could productively cover.

**Time budget**:
- Recruiter / HR / hunter: read all of this doc (~10 min).
- Technical leader / architect peer: skim section 1 (stance), then jump to [`docs/decisions/`](decisions/) for the 13 ADRs and [`docs/incidents.md`](incidents.md) for the 24 postmortems.

---

## 1. Who this project is by — and what that means for the scope

Built solo by a **hands-on architect** — someone who designs cross-cutting systems AND implements them personally. Not a whiteboard-only architect. Not a ticket-slicing IC either. The stance is deliberately this combination:

- **Cross-cutting design, executed line-by-line.** Every Terraform module, every GitHub Actions workflow, every IAM policy, every runbook step, every ADR, every incident postmortem in this repo was written by the same person. No delegation, no copy-from-template, no "I designed it and handed it off to the IC team." Multi-account AWS governance, CI/CD pipelines, Kubernetes platform bootstrap, security posture, cost discipline — all implemented, not just specified.
- **Specialist depth is NOT the claim.** Algorithm-level optimization, deep IAM policy minimization, Kubernetes controller-manager internals, release-engineering of upstream open-source projects — these appear in the project because they are unavoidable, but they are handled by *following published patterns from canonical sources* with clear hand-off notes, not by original invention. When a specialist joins the team, they add depth where my breadth has reached its limit.

This split is explicit for a reason: a hands-on architect's value comes from shipping the cross-cutting system AND being technically credible to operate it. Pretending to also be a deep specialist in every area I touched would break the first technical question. Stating the boundary honestly is the senior signal; hiding it would undersell the execution and over-claim the depth simultaneously.

The project value is execution and discipline, layered together:

- **Execution**: the entire repo is working code — Terraform applies cleanly, CI applies to a live AWS organization, the EKS platform bootstraps end-to-end in one workflow dispatch. See the [Phase table in README](../README.md#phases) for what's actually deployed on `main`, not aspirations.
- 13 [Architecture Decision Records](decisions/) (including several "Design iteration" sections documenting *reversed* decisions honestly)
- 20+ [incident postmortems](incidents.md) (each written after the fact in a consistent format, never softened retroactively)
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
- **ADRs** — 13 in [`docs/decisions/`](decisions/), supersede-in-place style ("Design iteration" sections note evolution)
- **Incidents** — 24 in [`docs/incidents.md`](incidents.md), append-only, standard format
- **Runbooks** — 3 in [`docs/runbooks/`](runbooks/); CLAUDE.md rule requires AI agents to read the layer's runbook before operating on it

**Where to look**:
- [`CLAUDE.md`](../CLAUDE.md) — 6 explicit "Rule: AI must..." clauses
- [`docs/decisions/`](decisions/) — 13 ADRs
- [`docs/incidents.md`](incidents.md) — 24 postmortems
- [`docs/runbooks/`](runbooks/) — 3 runbooks

**Likely questions**: show me a real incident (pick from the 24 in `docs/incidents.md` — Incidents 6, 7, 12, 18, 22, 24 cover the widest angle: CMK recovery, hidden cross-account prerequisites, honest design reversal, asymmetric IAM policy, belt-and-suspenders teardown architecture, and Terraform concurrency edge cases); what does the ADR format give you that code comments don't (ADRs preserve *why* even when *what* is obvious from code); how do you keep this discipline consistent (CLAUDE.md rules + pre-commit hooks + AI reminders — not willpower).

### 2.7 Cost governance

**Built**: $30/month + $10/day AWS Budgets. Baseline layers cost < $5/mo; workload layers cost $5-10/session when running. Teardown is a first-class feature: three scripts (soft for session end, hard for project end with triple confirmation + anti-CI flag, emergency cloud-nuke for drift recovery). Karpenter NodePool has a hard 4-vCPU cluster-wide cap as a cost backstop.

**Where to look**:
- [`CLAUDE.md`](../CLAUDE.md) "Cost Guardrails" section
- [`scripts/teardown/`](../scripts/teardown/) + [`scripts/teardown/README.md`](../scripts/teardown/README.md) decision tree
- [`scripts/emergency/nuke-workload-account.sh`](../scripts/emergency/nuke-workload-account.sh)
- [`terraform/environments/staging/platform/karpenter-nodepool.tf`](../terraform/environments/staging/platform/karpenter-nodepool.tf) — `limits: { cpu: "4", memory: "16Gi" }`

**Likely questions**: what prevents a forgotten teardown (budget alerts + CLAUDE.md rule + one-command soft teardown); soft vs hard teardown (soft preserves state bucket and all non-workload resources; hard calls CloseAccount → 90-day suspension); worst-case leak (EKS + NAT + Fargate = ~$135/mo if forgotten; daily budget alert catches within 24h).

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
- **Operational discipline**: 13 ADRs + 24 incident postmortems + 3 runbooks, each written to a consistent format, never softened retroactively.
- **Production-shaped patterns** — not production-*hardened* (the lab is single-operator, single-region-primary, no DR-tested, no SOC 2 audit trail). The patterns are transferable to production; the lab itself isn't production.
- **Reproducibility**: a single `config/landing-zone.yaml` + two shell scripts land the whole foundation in a fresh AWS organization. Fork-and-deploy is not a slogan here; it's tested.

### What is NOT claimed

- **IAM policy authoring as a specialty.** Both the Karpenter controller policy ([`karpenter-iam.tf`](../terraform/environments/staging/platform/karpenter-iam.tf)) and the AWS Load Balancer Controller policy ([`lb-controller-policy.json`](../terraform/environments/staging/platform/lb-controller-policy.json)) are adapted from canonical upstream sources (Karpenter's CloudFormation template; `kubernetes-sigs/aws-load-balancer-controller` v2.8.2's published policy). A deeper specialist would use the `terraform-aws-modules/eks/karpenter` sub-module and not own the Karpenter policy at all. The choice to inline was to keep the policy reviewable in one place for this project's scope; at enterprise scale, the sub-module is the right pivot.
- **Kubernetes internals as a specialty.** Enough to bootstrap a cluster, reason about Access Entries vs aws-auth ConfigMap, and wire up IRSA. Not enough to answer deep questions about CRD schema evolution, controller-manager reconciliation loops, or scheduler internals.
- **Karpenter / ArgoCD internals as a specialty.** Install + configure + diagnose connectivity; I do not claim to know what changed internally between Karpenter v0.37 → v1.0 beyond what the release notes say.
- **Algorithm-level optimization.** When a teardown takes 20 minutes due to IPAM release lag ([ADR-004 Consequences](decisions/004-deployment-configuration-contract.md)), the answer is "live with it, document it, adjust timeouts." A specialist might investigate whether there's a faster release path; that investigation is not in scope for a hands-on architect whose job is shipping the cross-cutting system.
- **Network deep-dive.** VPC design (subnets, NAT, Gateway endpoints) follows public reference architectures. Deep questions about BGP, IPv6 dual-stack, Transit Gateway attachment routing, or MTU tuning are outside the scope of this project.
- **Production observability** — reserved for Phase 4. Currently: CloudTrail (aggregated in `aegis-logarchive`), AWS Config (aggregated), CloudWatch log groups with 365-day retention on EKS control plane. Prometheus, Grafana, Datadog-style stacks are deferred.
- **DR testing.** Control Tower governs two regions (eu-central-1 primary, eu-west-1 DR), but no DR failover has been tested end-to-end. The DR region is set up for future work.
- **Compliance audit readiness.** ISO 27001 alignment is the guardrail ([ADR-005](decisions/005-compliance-framework-iso-27001.md)). Closest specific control: AWS Config conformance packs could be enabled in `aegis-security` if required — not done here. No SOC 2 / PCI / HIPAA claims.

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

### Phase 4 — Observability + security-at-cluster (not started)
Prometheus + Grafana, VPC Flow Logs, GuardDuty, Security Hub, AWS Config conformance packs.

### Phase 5 — Service mesh + per-pod TLS (not started)
cert-manager, service mesh mTLS, private endpoints, EKS Pod Identity migration.

---

## 6. Where to go for the deep dive

This doc is frame-level. For the actual substance:

| Interest | Open |
|---|---|
| "Walk me through the architectural decisions" | [`docs/decisions/`](decisions/) — 13 ADRs |
| "Show me real failures and what you learned" | [`docs/incidents.md`](incidents.md) — 24 postmortems |
| "How do I reproduce this?" | [`docs/runbooks/001-bootstrap-aws-account.md`](runbooks/001-bootstrap-aws-account.md) |
| "How would an AI agent work on this?" | [`CLAUDE.md`](../CLAUDE.md) |
| "What does the config contract look like?" | [`config/landing-zone.example.yaml`](../config/landing-zone.example.yaml) + [`config/schema.json`](../config/schema.json) + [ADR-004](decisions/004-deployment-configuration-contract.md) |
| "Most interesting Terraform surface" | [`terraform/environments/staging/platform/`](../terraform/environments/staging/platform/) — EKS platform, 15 `.tf` files |

---

*Last updated: 2026-04-15 — Post-Phase-3c ops hygiene sweep (provider v6 + Incidents 23/24 + GitHub security posture).*
