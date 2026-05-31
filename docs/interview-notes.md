<!-- session-close-review: recruiter-facing narrative; scope reflects the account-fabric scope; ADR/incident/runbook counts in §2.6 must agree with the actual file set -->
# Interview Notes

A reader's guide for recruiters, hiring managers, and technical leadership reviewing this project as a portfolio artifact. Different from the rest of the repo, this document is written *about* the project rather than *inside* it — its job is to frame scope, stance, and what a conversation could productively cover.

> **Forking this repo?** This document is portfolio-framing, not operational guidance — start with [`README.md`](../README.md) for the architecture overview and [`docs/runbooks/`](runbooks/) for how-to walk-throughs.

> **Scope note.** This repository owns the **AWS account fabric** — multi-account governance, SCPs, Identity Center, account vending, the security/audit baseline, the GitHub OIDC provider, and org-wide IPAM. Cluster, GitOps, and workload concerns run in a separate platform repository and are out of scope here. This document frames the account-fabric repo.

**Time budget**:
- Recruiter / HR / hunter: read all of this doc (~8 min).
- Technical leader / architect peer: skim section 1 (stance), then jump to [`docs/decisions/`](decisions/) for the ADRs and [`docs/incidents.md`](incidents.md) for the postmortems.

---

## 1. Who this project is by — and what that means for the scope

Built solo by a **hands-on architect** — someone who designs cross-cutting systems AND implements them personally. Not a whiteboard-only architect. Not a ticket-slicing IC either. The stance is deliberately this combination:

- **Cross-cutting design, executed line-by-line.** Every Terraform module, every GitHub Actions workflow, every IAM policy, every runbook step, every ADR, every incident postmortem in this repo was written by the same person. No delegation, no copy-from-template, no "I designed it and handed it off to the IC team." Multi-account AWS governance, account vending, CI/CD pipelines, OIDC federation, security posture, cost discipline — all implemented, not just specified.
- **Specialist depth is NOT the claim.** Deep IAM policy minimization, AWS Config rule authoring internals, release-engineering of upstream open-source projects — these appear in the project because they are unavoidable, but they are handled by *following published patterns from canonical sources* with clear hand-off notes, not by original invention. When a specialist joins the team, they add depth where my breadth has reached its limit.

This split is explicit for a reason: a hands-on architect's value comes from shipping the cross-cutting system AND being technically credible to operate it. Pretending to also be a deep specialist in every area I touched would break the first technical question. Stating the boundary honestly is the senior signal; hiding it would undersell the execution and over-claim the depth simultaneously.

The project value is execution and discipline, layered together:

- **Execution**: the entire repo is working code — Terraform applies cleanly, CI applies to a live AWS organization, the account fabric bootstraps end-to-end from a documented runbook. See the [README](../README.md) for what's actually deployed on `main`.
- A set of [Architecture Decision Records](decisions/) covering every load-bearing governance choice, several with honest "Design iteration" sections documenting decisions that were revisited.
- [Incident postmortems](incidents.md), each written after the fact in a consistent format, never softened retroactively.
- A CI/CD design shaped by the no-static-credentials principle — `terraform-plan` on PR, `terraform-apply-baseline` on merge — not template copy-paste.
- A runbook covering both the happy path and the "here is how to debug when it breaks" diagnostic order.
- A config contract that makes the whole account fabric forkable in one YAML file.

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

### 2.2 CI/CD — OIDC-federated, no static credentials

**Built**: GitHub Actions workflows for the account fabric — `terraform-plan.yml` comments the plan on every PR, `terraform-apply-baseline.yml` auto-applies on merge to main, `checkov.yml` runs the IaC security scan. OIDC federation throughout; zero static AWS credentials in the repo. Every layer here is a cheap persistent baseline, so a single auto-apply workflow covers all of it — there is no manual-dispatch / approval-gated apply path.

**Where to look**:
- [`docs/decisions/009-lifecycle-and-teardown-strategy.md`](decisions/009-lifecycle-and-teardown-strategy.md)
- [`.github/workflows/`](../.github/workflows/) — the three workflows
- [`scripts/teardown/hard-teardown-landing-zone.sh`](../scripts/teardown/) — project-end destroy with triple confirmation

**Likely questions**: why OIDC instead of IAM users (zero-static-credentials principle, OIDC subject-claim scoping per ADR-014); what happens on rollback (`git revert` + CI re-apply — see [`docs/principles/change-review-discipline.md`](principles/change-review-discipline.md) §2.4); why is there no per-session destroy (the account fabric has no idle-billing resources — see [`docs/finops.md`](finops.md)).

### 2.3 Account bootstrap and vending

**Built**: the full bootstrap path from a fresh AWS account to a governed organization — Control Tower landing zone, IAM Identity Center, the Terraform S3 state backend with a customer-managed CMK, the GitHub OIDC identity provider, and member-account vending. Two provisioning paths (manual Account Factory today, AFT committed and CI-validated for the scaling path).

**Where to look**:
- [`docs/runbooks/001-bootstrap-aws-account.md`](runbooks/001-bootstrap-aws-account.md) — the step-by-step
- [`docs/decisions/010-shared-account-bootstrap-sequence.md`](decisions/010-shared-account-bootstrap-sequence.md) — the chicken-and-egg manual break
- [`docs/decisions/011-account-provisioning-two-path-strategy.md`](decisions/011-account-provisioning-two-path-strategy.md)
- [`terraform/environments/shared/`](../terraform/environments/shared/) — bootstrap, ipam, aft

**Likely questions**: how do you break the state-bucket / AFT chicken-and-egg cycle (one conscious manual account — ADR-010); why keep AFT committed but not deployed (the unused path stays fresh via CI validation — ADR-011).

### 2.4 Org-wide IPAM — the CIDR allocation authority

**Built**: AWS IPAM (Advanced Tier) in `aegis-shared`, RAM-shared to the whole organization. Top pool 10.0.0.0/8, per-region pools. Any downstream consumer allocates VPC CIDRs via `ipv4_ipam_pool_id` with no hand-planned CIDR math. The account fabric owns the *allocation authority*; it does not own the VPCs that consume it.

**Where to look**:
- [`docs/decisions/012-ipam-and-cidr-allocation.md`](decisions/012-ipam-and-cidr-allocation.md)
- [`terraform/environments/shared/ipam/`](../terraform/environments/shared/ipam/)
- [`docs/incidents.md`](incidents.md) Incident 7 — the cross-account prerequisite discovery story

**Likely questions**: why IPAM over static CIDR allocation (enforces non-overlap at API level, conflict-free namespace shared org-wide); why does the fabric own the pools but not the VPCs (the fabric vends a governed namespace; consumers draw from it — this is the fabric-vs-platform boundary in miniature).

### 2.5 Security and audit baseline

**Built**: three SCPs at org root. Customer-managed KMS keys for the cross-account state bucket (with key policy granting `kms:Decrypt` to `aws:PrincipalOrgID`) and for the CloudTrail/Config log archive. Organization-wide CloudTrail trail and AWS Config feeding the `aegis-logarchive` account; GuardDuty enabled org-wide. GitHub OIDC with subject-claim scoping. No IAM users anywhere by design.

**Where to look**:
- [`docs/decisions/005-compliance-framework-iso-27001.md`](decisions/005-compliance-framework-iso-27001.md)
- [`terraform/environments/management/scps/`](../terraform/environments/management/scps/)
- [`terraform/environments/shared/bootstrap/`](../terraform/environments/shared/bootstrap/) — state-bucket KMS
- [`terraform/environments/staging/bootstrap/`](../terraform/environments/staging/bootstrap/) — the GitHub OIDC role

**Likely questions**: what is and isn't a secret in this repo ([`CLAUDE.md` "Security" section](../CLAUDE.md) lists both); how key rotation works (AWS-handled via `enable_key_rotation = true`); break-glass approach (cold root + admin bypass on branch protection — see [`docs/principles/break-glass-apply.md`](principles/break-glass-apply.md)).

### 2.6 Operational discipline (ADRs, incidents, runbook)

**Built**: three layers of operational writing with explicit rules in [`CLAUDE.md`](../CLAUDE.md):
- **ADRs** in [`docs/decisions/`](decisions/), supersede-in-place style — "Design iteration" sections note where a decision was revisited.
- **Incidents** in [`docs/incidents.md`](incidents.md), append-only, standard format.
- **Runbook** — [`docs/runbooks/001-bootstrap-aws-account.md`](runbooks/001-bootstrap-aws-account.md), the account-fabric bootstrap walk-through; CLAUDE.md rule requires AI agents to read the layer's runbook before operating on it.

**Where to look**:
- [`CLAUDE.md`](../CLAUDE.md) — explicit "Rule: AI must..." clauses
- [`docs/decisions/`](decisions/) — the ADR set
- [`docs/incidents.md`](incidents.md) — the postmortems
- [`docs/principles/`](principles/) — 2 cross-cutting discipline docs (change-review, break-glass-apply)

**Likely questions**: show me a real incident (Incidents 6, 7 cover the widest angle for the account fabric — CMK recovery within the KMS grace window, and hidden cross-account prerequisites for IPAM); what does the ADR format give you that code comments don't (ADRs preserve *why* even when *what* is obvious from code); how do you keep this discipline consistent (CLAUDE.md rules + pre-commit hooks + AI reminders — not willpower).

### 2.7 Cross-repo coordination

**Built**: a durable coordination protocol between independently-maintained repositories. The account fabric (`aegis-landing-zone-aws`) vends accounts, OIDC, and IPAM pools that downstream platform and application repositories consume. Standing GitHub Issues serve as the contract surface; label semantics (`cross-repo`, `cross-repo/blocking`, `cross-repo/fyi`) govern urgency. Either side can open issues on the other.

**Where to look**:
- [README §Cross-repo coordination](../README.md#cross-repo-coordination)
- [`CLAUDE.md`](../CLAUDE.md) "Cross-repo coordination" section (operational rules for AI agents)

**Likely questions**: why Issues instead of a shared config file or API contract (audit trail + async-first — agents and humans both see the same history); how do you prevent drift between the contract and reality (CLAUDE.md rule: PRs that change the platform-facing surface must update the standing issue in the same PR); why a multi-repo shape (a landing zone and a platform are different things with different consumers — they belong in separate repositories).

### 2.8 Cost governance

**Built**: $30/month + $10/day AWS Budgets in the management account. The account fabric is an always-on baseline of ~$5/month (Control Tower + AWS Config recorder + CloudTrail + S3 log storage + KMS). There are no per-session cost-incurring resources in this repo — no EKS, no NAT, no ALB. IPAM Advanced tier is the only usage-priced item, and it is ~$0 while idle. The cost story is documented in full in [`docs/finops.md`](finops.md).

**Where to look**:
- [`CLAUDE.md`](../CLAUDE.md) "Cost Guardrails" section
- [`docs/finops.md`](finops.md) — the account-fabric cost model
- [`scripts/teardown/`](../scripts/teardown/) — the hard destroy (project-end) and emergency cloud-nuke scripts

**Likely questions**: what does the account fabric cost idle (~$5/month — Control Tower baseline; see `docs/finops.md`); why no per-session destroy discipline here (there is nothing that bills while idle); what is the one usage-priced line item (IPAM Advanced tier, ~$0 idle, cents per month once a consumer allocates).

---

## 3. Conservative-by-design — "why not the absolute newest"

This project picks the **current-stable** version of each tool rather than the absolute newest. Each choice has a reason, and the reason is the signal. Chasing bleeding-edge is not senior behavior; *choosing stable with awareness of the trade-off* is.

| Tool / feature | Chosen | Newest-available | Why conservative |
|---|---|---|---|
| Terraform | 1.14.8 | 1.14.8 | Current stable; `use_lockfile = true` needs ≥ 1.10. |
| AWS provider | `~> 5.0` | 6.x | Tracked via open Dependabot PRs for a deliberate review rather than an automatic major bump. |
| Account provisioning | Path A (Service Catalog) | Path B (AFT) | AFT scales better; Path A is simpler to reason about at the current account count. AFT code committed in `terraform/environments/shared/aft/` but not applied (ADR-011). |
| State locking | S3 native (`use_lockfile`) | (same) | Drops the DynamoDB lock table — one fewer billed resource, current-stable since Terraform 1.10. |

The pattern: **"I chose X not Y because Z, and the migration to Y is tracked at location W."** Every row above follows this shape.

---

## 4. Explicit scope-of-claims

Positive statements of what this project demonstrates, paired with explicit statements of what it does *not* demonstrate. The honest framing is the point; claiming everything would be a red flag.

### What is claimed

- **Cross-cutting architectural design of an AWS account fabric**: composing AWS Organizations, Control Tower, SCPs, Identity Center, IPAM, the security/audit baseline, and a no-static-credentials CI/CD pipeline into a working multi-account governance foundation, with explicit decisions (ADRs) and documented trade-offs.
- **Definitional judgment**: distinguishing an account fabric (vends and governs accounts) from a platform (runs workloads inside them), and scoping the repository to the fabric alone so it stays reusable under any platform.
- **Operational discipline**: ADRs + incident postmortems + a bootstrap runbook + 2 cross-cutting principle docs, each written to a consistent format, never softened retroactively.
- **Production-shaped patterns** — not production-*hardened* (the lab is single-operator, single-region-primary, no SOC 2 audit trail). The patterns are transferable to production; the lab itself isn't production.
- **Reproducibility**: a single `config/landing-zone.yaml` + two shell scripts land the whole account fabric in a fresh AWS organization. Fork-and-deploy is not a slogan here; it's tested.

### What is NOT claimed

- **Kubernetes / EKS hands-on as a deliverable of this repo.** EKS, Karpenter, ArgoCD, cluster admission control, and IRSA are platform concerns and out of scope here. The account fabric *enables* a platform (it vends the accounts, the OIDC provider, and the IPAM pools a platform consumes) but does not *contain* one.
- **GitOps / continuous delivery hands-on.** ArgoCD and the app-of-apps pattern are platform concerns. This repo's CI/CD is Terraform plan/apply for the account fabric only.
- **Observability at scale.** The in-cluster observability stack is a platform concern. The account fabric's "observability" is CloudTrail + AWS Config + GuardDuty — audit and detection, not application telemetry.
- **Edge / CDN and application auth.** CloudFront/ACM/Route53 and an application auth layer are platform concerns and out of scope here.
- **IAM policy authoring as a specialty.** SCPs and the state-bucket / OIDC trust policies are written here, but a deeper specialist would minimize them further or generate them from a higher-level abstraction. The policies are reviewable in one place by design; at enterprise scale, finer-grained per-environment IAM paths are the documented pivot.
- **DR testing.** Control Tower governs two regions (eu-central-1 primary, eu-west-1 DR), but no DR failover has been tested end-to-end. The DR region is set up for future work; the state-backend cross-region replica is a documented improvement, not an implemented one.
- **Compliance audit readiness.** ISO 27001 alignment is the guardrail ([ADR-005](decisions/005-compliance-framework-iso-27001.md)). The fabric demonstrates the *patterns* — SCP guardrails, immutable audit trail, encryption-by-default — not the completeness of a SOC 2 / PCI / HIPAA audit-ready control set.

### Positive framing for the interview

> "I'm a hands-on architect — I design cross-cutting systems and build them myself, line by line. This repo is the AWS account fabric: the multi-account governance foundation a team stands up before any workload. It is scoped deliberately to the fabric — Organizations, OUs, SCPs, Identity Center, account vending, IPAM, the security baseline — and stops there, because a landing zone and the platform that runs on it are different things with different consumers. Keeping that boundary crisp is what keeps the fabric reusable under any platform; the definitional clarity is the senior signal."

---

## 5. Narrative arc — the story to tell

### Phase 0 — Bootstrap (done)
AWS Control Tower landing zone + management account IAM + cold root. [Runbook 001](runbooks/001-bootstrap-aws-account.md) is the step-by-step. Incidents 1 (KMS policy), 2 (account alias), 3 (RAM + apply order) landed here.

### Phase 1 — Foundation (done)
IAM Identity Center, SSO user, permission set, cross-account IAM; Terraform state bucket with CMK in `aegis-shared`. Incident 5 (cross-account `kms:Decrypt` with `aws/s3`) landed here.

### Phase 2 — GitOps pipeline (done)
GitHub OIDC, GitHub Actions workflows for the account fabric (plan on PR, apply-baseline on merge), Checkov + pre-commit. Incidents 3 and 6 (CMK destroyed by CI) landed here.

### Phase 3 — IPAM (done)
Org-wide AWS IPAM in `aegis-shared`, RAM-shared to the whole organization as the conflict-free CIDR allocation authority. Incident 7 (IPAM delegated admin not configured for cross-account allocation) landed here.

### Phase 4 — Security baseline (done)
Organization-wide CloudTrail and AWS Config feeding `aegis-logarchive`, GuardDuty org-wide, and the layered IAM scope-down ladder (ADR-014–016 — CI OIDC role scope-down, permission-boundary hardening, and the detective control that alerts on a failed OIDC assumption).

---

## 6. Where to go for the deep dive

This doc is frame-level. For the actual substance:

| Interest | Open |
|---|---|
| "Walk me through the architectural decisions" | [`docs/decisions/`](decisions/) |
| "Show me real failures and what you learned" | [`docs/incidents.md`](incidents.md) |
| "How do I reproduce this?" | [`docs/runbooks/001-bootstrap-aws-account.md`](runbooks/001-bootstrap-aws-account.md) |
| "How would an AI agent work on this?" | [`CLAUDE.md`](../CLAUDE.md) |
| "What does the config contract look like?" | [`config/landing-zone.example.yaml`](../config/landing-zone.example.yaml) + [`config/schema.json`](../config/schema.json) + [ADR-004](decisions/004-deployment-configuration-contract.md) |
| "What does it cost to run?" | [`docs/finops.md`](finops.md) — the account-fabric cost model |

---

*This document frames the AWS account fabric: multi-account governance, SCPs, Identity Center, account vending, the security/audit baseline, the GitHub OIDC provider, and org-wide IPAM. Cluster, GitOps, and workload concerns run in a separate platform repository and are out of scope here.*
