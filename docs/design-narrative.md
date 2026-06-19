<!-- session-close-review: war story references match incident count, retrospective still accurate, scope reflects the account-fabric scope -->
# Design Narrative

A narrative companion to the ADRs. The ADRs capture individual decisions in their own right. This document connects the dots — what the project is trying to prove, what trade-offs were made consciously, what went wrong, and what the scaling path looks like.

## The 30-second version

This project is a reference implementation of an **AWS account fabric** — the multi-account governance foundation a small team stands up *before* it deploys any workload. It demonstrates senior-level architectural thinking — not by reinventing AWS primitives but by making every load-bearing decision explicit and defensible. Architecture Decision Records in [`docs/decisions/`](decisions/) capture the *why* of every choice. A detailed runbook documents every manual bootstrap step plus the gotchas that broke the first attempt. End-to-end deployment is a config-only operation: one YAML file, two shell scripts, one GitHub pull request.

## The 2-minute version

Most AWS landing zone references aim at enterprise scale — AWS Landing Zone Accelerator is 50+ CloudFormation stacks; Gruntwork's Reference Architecture assumes a team paying for the product. This project takes the opposite approach: scope down to what a single operator or small team actually needs, produce something that is both *functional* and *readable*, and make every decision explicit enough that a reviewer can trace each line of Terraform back to the reasoning that produced it.

**The repository is deliberately scoped to the account fabric and nothing more.** It owns: AWS Organizations and OUs, Service Control Policies, IAM Identity Center, account bootstrap and vending (Control Tower + Terraform hybrid, AFT, the Terraform S3 state backend, the GitHub OIDC identity provider), the centralized security/audit baseline (CloudTrail org trail, AWS Config, GuardDuty), and the org-wide IPAM that is the RAM-shared CIDR allocation authority. Everything that *runs on top of* the fabric — VPC/network, EKS, ArgoCD, observability, edge, auth — runs in a separate platform repository and is out of scope here. A landing zone vends and governs accounts; the things that run inside those accounts are platforms, and keeping that boundary crisp is a deliberate design choice — see *The fabric-versus-platform boundary* below.

The project is organized around six design principles that live at the top of the README. Every ADR traces back to at least one of them:

1. Trade cost for reproducibility, not vice versa
2. Document decisions, not just code
3. A landing zone is the account fabric, not the platform.
4. Zero static credentials. Anywhere.
5. Drift is a bug.
6. Automate the steady state. Accept one manual break.

The first principle is the reason `config/landing-zone.yaml` + `scripts/configure-backends.sh` exists. The second is the reason every load-bearing decision has its own ADR. The third is why this repo carries no idle-billing resources — the account fabric governs accounts; it does not run workloads. The fourth is enforced by a Service Control Policy at the organization level, not just IAM policy. The fifth is why the README and the architecture diagrams update in the same PR as the code. The sixth is why `aegis-shared` is created by hand and every other account is fully automated.

None of these were obvious up front. They emerged from working through the actual constraints and will be explained below.

## Key decisions and their reasoning

### Control Tower + Terraform hybrid, not hand-rolled (ADR-008)

Hand-rolling `aws_organizations_organization`, OU definitions, and baseline SCPs from scratch would demonstrate essentially nothing that was not already in my résumé. I have five years of production AWS Organizations experience from a prior role. Spending two weeks on boilerplate I already know would consume time that should go to the actual learning goals of this project — GitHub Actions, OIDC federation, signed commits, multi-account governance discipline.

Control Tower handles the foundation. Terraform handles the extensions. The boundary between them is articulated in ADR-008: Control Tower gets everything AWS provides natively (organizational CloudTrail, baseline guardrails, account enrollment); Terraform gets everything portfolio-relevant (custom SCPs, OIDC, state management).

The interview answer to *"why did you use Control Tower?"* and *"why didn't you use Control Tower?"* is the same: **both use cases are served by the same ADR**. The decision was made once, with alternatives considered on record, and is equally defensible from either direction. That's what a well-written ADR does.

### Two-path account provisioning, not a binary choice (ADR-011)

The obvious decisions would be: use AFT and pay $10–15/month for CI infrastructure you will use twice; or skip AFT and lose the scaling path entirely. Neither is right for a project that wants to stay small but demonstrate understanding of both patterns.

The project supports both paths. Current deployment uses manual Account Factory (zero ongoing cost). The AFT Terraform code is committed, version-pinned, `terraform validate`-clean, and CI-checked on every PR. When scale or multi-team self-service justifies it, AFT activation is a `terraform apply` away. The unused path does not rot because CI validates it on every commit.

This pattern — *support both paths, let the operator pick at deployment time, write the unused path in a way that stays fresh* — is how architecture avoids false binary decisions. It costs one ADR to document. It protects the project from being a dead-end at scale.

### The one manual account that breaks the bootstrap cycle (ADR-010)

The Terraform state bucket lives in `aegis-shared`. AFT requires the state bucket to exist. But AFT is how new accounts get provisioned. Chicken, meet egg.

Every multi-account AWS landing zone faces this exact cycle. Some projects ignore it and put state in the management account (violates ADR-001 boundary). Some invoke CloudFormation before Terraform. This project accepts one manual account creation — `aegis-shared`, created by hand via Control Tower Account Factory — and then automates everything after. One conscious manual step, explicitly documented as *the* manual step, not "many manual steps we didn't bother to automate."

### IPAM as the org-wide CIDR allocation authority (ADR-012)

Hand-planned CIDR ranges are a classic multi-account footgun: two VPCs overlap, and the discovery happens at VPC-peering or Transit-Gateway-attachment time, long after the mistake was cheap to fix. This project puts AWS IPAM (Advanced tier) in `aegis-shared`, builds a top pool of `10.0.0.0/8` with per-region sub-pools, and RAM-shares those pools to the entire organization.

The account fabric owns the *allocation authority* — the pools and the RAM share. It does not own the VPCs that draw from them; those belong to a downstream consumer. This is the cleanest example of the fabric-vs-platform boundary: the fabric provides a *governed, conflict-free namespace*, and any consumer allocates from it via `ipv4_ipam_pool_id` without ever doing CIDR math by hand.

### The fabric-versus-platform boundary

This is the decision a reviewer should ask about first.

A landing zone's job is to **vend and govern accounts**. The things that *run inside* those accounts — VPCs, EKS, ArgoCD, observability, edge, auth — are platforms, and platforms are plural: more than one workload repository can deploy into the same set of accounts. The account fabric and a platform have different audiences, different change cadences, and different consumers, so they belong in different repositories.

This repository owns only the fabric: AWS Organizations and OUs, Service Control Policies, IAM Identity Center, account bootstrap and vending, the Terraform S3 state backend, the GitHub OIDC identity provider, the centralized security/audit baseline, and the org-wide IPAM. A platform is a separate repository and an independent consumer of the fabric's accounts, OIDC, and IPAM pools.

Distinguishing a landing zone (the account fabric) from a platform (a workload-bearing consumer of the fabric) is exactly the kind of definitional clarity that separates a senior architect from someone assembling AWS services. The fabric is shaped to be reusable under *any* platform: globally-namespaced resources carry the full repository name as a collision-free prefix, and the OIDC provider is a shared account-scoped singleton that downstream consumers reuse rather than recreate.

## War stories

Real incidents from this project's deployment history are kept in [`docs/incidents.md`](incidents.md) as postmortem-style entries (Symptom → Root cause → Detection → Resolution → Prevention → Lessons). Highlights below illustrate the *kind* of issues a multi-account account fabric surfaces — not a prescriptive checklist a forker should expect to encounter in this exact order or set:

- **KMS key policy wasn't enough at Control Tower launch** — the wizard's default key policy was missing CloudTrail and Config service principals. Rollback itself failed because a CloudWatch Log Group couldn't be cleaned up. See [Incident 1](incidents.md#incident-1--kms-key-policy-insufficient-at-control-tower-launch).
- **IAM alias collided with another AWS customer worldwide** — aliases are globally unique, not org-scoped. `list-account-aliases` returning empty is not proof the alias is available. Fixed by `binhsu-` prefix. See [Incident 2](incidents.md#incident-2--iam-account-alias-globally-unique-collision).
- **RAM cross-org sharing required two PRs** — one to enable it, one to fix the apply matrix order. See [Incident 3](incidents.md#incident-3--ram-cross-org-sharing-requires-explicit-enablement-and-correct-apply-order).
- **Control Tower UI showed stale state** — API reported IN_SYNC, UI still showed drift. Hard-refresh fixed it. See [Incident 4](incidents.md#incident-4--control-tower-ui-stale-after-landing-zone-update).
- **Cross-account `kms:Decrypt` denied with the default AWS-managed key** — forced migration to a customer-managed KMS key with `aws:PrincipalOrgID` key policy. See [Incident 5](incidents.md#incident-5--cross-account-kmsdecrypt-denied-with-the-awss3-default-key).
- **State bucket CMK scheduled for deletion by CI apply** — local apply from an unmerged branch created state drift that CI later "corrected" by destroying the CMK. Recovered in ~15 minutes within the KMS grace window. See [Incident 6](incidents.md#incident-6--state-bucket-cmk-scheduled-for-deletion-by-ci-apply).

Every one of these is an account-fabric incident — Organizations, Control Tower, KMS, RAM, state backend.

The lesson that threads through all six: **the value of this project is not that it's perfect — it's that the path from imperfect to working is visible and audit-able in git history, in runbook updates, and in the incidents log.**

## Trade-offs consciously made

Several decisions were made knowing they are not the production-correct answer, because production-correct answers would push the project past a single operator's budget or attention span:

- **Manual Account Factory over AFT** — Path A in ADR-011; zero ongoing cost at 2-account scale, AFT code committed and CI-validated so the scaling path stays fresh
- **`aws:PrincipalOrgID` condition over per-environment IAM paths** — coarser than production-grade per-layer state access, but adequate and auditable at lab scale; the finer-grained path is documented as the scaling step
- **Single org CloudTrail trail, no S3 access logging on the state bucket** — accepted lab-scale gaps, each flagged in the relevant ADR's *Consequences* or *Future Hardening* section

Each appears in an ADR's *Alternatives Considered* or *Consequences* section, with the reasoning on record. None were defaults accepted by accident.

## What this would look like at scale

If this account fabric were deployed for a real organization instead of a lab, the ADRs flag where the trade-offs flip. The scaling path is already documented; it is not an afterthought:

- **AFT pipeline activated** — Path B from ADR-011 becomes the default account provisioning mechanism once self-service account vending is needed
- **Per-layer granular IAM** for cross-account state access, replacing the current `aws:PrincipalOrgID` condition with per-environment IAM path conditions
- **S3 access logging** on the state bucket (ISO 27001 Annex A.8.15)
- **Cross-region + cross-account state replication** to `aegis-logarchive` in the DR region — the worked example in [`docs/improvements/001-state-backend-spof.md`](improvements/001-state-backend-spof.md)
- **Per-team OU split** with team-scoped SCPs, once multiple teams exist
- **Multiple platform repositories** vending into the same fabric — the account fabric is already shaped for this (repo-scoped resource naming, OIDC provider as a shared singleton); each platform is an independent consumer of the fabric's accounts, OIDC, and IPAM pools

Every one of these is either an *Alternatives Considered* entry, a *Future Hardening* section, or a *Consequences* paragraph in the relevant ADR. The document trail scales with the project.

## What I would do differently

These are honest retrospectives, not false-modesty performances:

- **Start with `.github/workflows/` from day one.** Phase 1 work was done through local `terraform apply` commands. Moving to PR-based CI/CD in Phase 2 was strictly better. The lesson: if PR-based flow is the end state, it should be the start state too. Starting earlier would have caught the management/shared/ipam apply-order issue before it became a production incident in PR #7.
- **Write ADRs as decisions are being made, not in batches after the fact.** The early ADRs (001–009) were written together after key decisions had already crystallized. Later ADRs were written *during* the decision process and are noticeably sharper — the "Alternatives Considered" sections are more specific because I could see the alternatives in real time, not reconstruct them later.
- **Use the `gh` CLI from the start.** Every `gh api` command in the runbook is replayable by a future operator. Every "click Settings → Branches → Add rule" in an earlier draft was not. The runbook is more useful the further it leans on CLI commands instead of console navigation.

## What this project demonstrates

For a technical reviewer reading this repository as part of an evaluation:

- **Senior-level architectural decision-making** — every load-bearing choice is explicit, reasoned, with alternatives rejected on record
- **Definitional clarity** — distinguishing an account fabric (vends and governs accounts) from a platform (runs workloads inside them)
- **Cost-consciousness at lab scale with an articulated scaling path to production**
- **Zero-credential security posture** — enforced by SCP at organization level, not just by policy
- **Documentation-first discipline** — ADRs for every load-bearing decision, a detailed bootstrap runbook, Mermaid architecture diagrams, explicit drift policy
- **Real infrastructure, not a tutorial** — six real AWS accounts, state in S3 with native locking, CI that actually applies to AWS via OIDC
- **Operational discipline** — signed commits required, branch protection with required status checks, admin bypass for documented legitimate cases
- **Self-correcting process** — the main branch's git history contains real mistakes with their fixes (KMS policy, RAM sharing, apply order, stale UI state). This is a feature, not a gap. A repository with no commit-history mistakes is either trivial or pretending.

That last point is worth repeating in interview context. **The value of this project is not that it is perfect. The value is that the path from imperfect to working is visible and audit-able.** Every gotcha is documented. Every fix is in a PR. Every ADR trace is a decision that could have gone the other way.
