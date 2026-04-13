# Design Narrative

A narrative companion to the ADRs. The ADRs capture individual decisions in their own right. This document connects the dots — what the project is trying to prove, what trade-offs were made consciously, what went wrong, and what the scaling path looks like.

## The 30-second version

This project is a reference implementation of a multi-account AWS landing zone for single-operator labs and small-team deployments. It demonstrates senior-level architectural thinking — not by reinventing AWS primitives but by making every load-bearing decision explicit and defensible. 13 Architecture Decision Records capture the *why* of every choice. A 10-part runbook documents every manual step plus the gotchas that broke the first attempt. End-to-end deployment is a config-only operation: one YAML file, two shell scripts, one GitHub pull request.

## The 2-minute version

Most AWS landing zone references aim at enterprise scale — AWS Landing Zone Accelerator is 50+ CloudFormation stacks; Gruntwork's Reference Architecture assumes a team paying for the product. This project takes the opposite approach: scope down to what a single operator or small team actually needs, produce something that is both *functional* and *readable*, and make every decision explicit enough that a reviewer can trace each line of Terraform back to the reasoning that produced it.

The project is organized around six design principles that live at the top of the README. Every ADR traces back to at least one of them:

1. Trade cost for reproducibility, not vice versa
2. Document decisions, not just code
3. Cost-conscious by default
4. Zero static credentials. Anywhere.
5. Drift is a bug
6. Automate the steady state. Accept one manual break.

The first principle is the reason `config/landing-zone.yaml` + `scripts/configure-backends.sh` exists. The second is the reason there are 13 ADRs instead of 3. The third is the reason there is one NAT Gateway instead of three. The fourth is enforced by a Service Control Policy at the organization level, not just IAM policy. The fifth is why the README and the architecture diagrams update in the same PR as the code. The sixth is why `aegis-shared` is created by hand and every other account is fully automated.

None of these were obvious up front. They emerged from working through the actual constraints and will be explained below.

## Key decisions and their reasoning

### Control Tower + Terraform hybrid, not hand-rolled (ADR-008)

Hand-rolling `aws_organizations_organization`, OU definitions, and baseline SCPs from scratch would demonstrate essentially nothing that was not already in my résumé. I have five years of production AWS Organizations experience from a prior role. Spending two weeks on boilerplate I already know would consume time that should go to the actual learning goals of this project — GitHub Actions, OIDC federation, Karpenter, signed commits.

Control Tower handles the foundation. Terraform handles the extensions. The boundary between them is articulated in ADR-008: Control Tower gets everything AWS provides natively (organizational CloudTrail, baseline guardrails, account enrollment); Terraform gets everything portfolio-relevant (custom SCPs, OIDC, state management, workload infrastructure).

The interview answer to *"why did you use Control Tower?"* and *"why didn't you use Control Tower?"* is the same: **both use cases are served by the same ADR**. The decision was made once, with alternatives considered on record, and is equally defensible from either direction. That's what a well-written ADR does.

### Single NAT Gateway, not three (ADR-012)

Production practice is one NAT per AZ. Three NATs cost $97/month always-on. A lab tolerates AZ-a going down and losing internet egress for a while. One NAT costs $32/month — 2.7× cheaper — and ADR-009's teardown discipline means it runs at most four hours per session anyway.

This is *the* cost-consciousness example. Not every "you're supposed to do it this way" pattern translates to every context. The project explicitly accepts the single-AZ NAT compromise and explicitly documents it as "not for production." When forked for a real production deployment, the operator has the full reasoning on record and can toggle to three NATs with one variable change.

### ACM over cert-manager, at least for Phase 3 (ADR-013)

The Kubernetes-community default for TLS is cert-manager + Let's Encrypt + ACME. It is an excellent pattern for multi-cloud portability, in-cluster TLS termination, and service mesh mTLS. None of those apply to a single ArgoCD UI cert behind an AWS-native ALB.

ACM + Application Load Balancer gives a free public certificate, renews automatically, requires no outbound internet egress from the cluster, and adds zero in-cluster operational surface. cert-manager is deferred to Phase 5, where service mesh mTLS will create an actual in-cluster TLS requirement.

The interview signal here is important: a senior engineer knows the community default *and* the situations where it is over-engineering. "What everyone uses" is not the same as "what this project needs." ADR-013 makes this reasoning explicit.

### Two-path account provisioning, not a binary choice (ADR-011)

The obvious decisions would be: use AFT and pay $10–15/month for CI infrastructure you will use twice; or skip AFT and lose the scaling path entirely. Neither is right for a project that wants to stay small but demonstrate understanding of both patterns.

The project supports both paths. Current deployment uses manual Account Factory (zero ongoing cost). The AFT Terraform code is committed, version-pinned, `terraform validate`-clean, and CI-checked on every PR. When scale or multi-team self-service justifies it, AFT activation is a `terraform apply` away. The unused path does not rot because CI validates it on every commit.

This pattern — *support both paths, let the operator pick at deployment time, write the unused path in a way that stays fresh* — is how architecture avoids false binary decisions. It costs one ADR to document. It protects the project from being a dead-end at scale.

### The one manual account that breaks the bootstrap cycle (ADR-010)

The Terraform state bucket lives in `aegis-shared`. AFT requires the state bucket to exist. But AFT is how new accounts get provisioned. Chicken, meet egg.

Every multi-account AWS landing zone faces this exact cycle. Some projects ignore it and put state in the management account (violates ADR-001 boundary). Some invoke CloudFormation before Terraform. This project accepts one manual account creation — `aegis-shared`, created by hand via Control Tower Account Factory — and then automates everything after. One conscious manual step, explicitly documented as *the* manual step, not "many manual steps we didn't bother to automate."

## War stories

Real incidents from this project's deployment are kept in [`docs/incidents.md`](incidents.md) as postmortem-style entries (Symptom → Root cause → Detection → Resolution → Prevention → Lessons). Highlights:

- **KMS key policy wasn't enough at Control Tower launch** — the wizard's default key policy was missing CloudTrail and Config service principals. Rollback itself failed because a CloudWatch Log Group couldn't be cleaned up. See [Incident 1](incidents.md#incident-1--kms-key-policy-insufficient-at-control-tower-launch).
- **IAM alias collided with another AWS customer worldwide** — aliases are globally unique, not org-scoped. `list-account-aliases` returning empty is not proof the alias is available. Fixed by `binhsu-` prefix. See [Incident 2](incidents.md#incident-2--iam-account-alias-globally-unique-collision).
- **RAM cross-org sharing required two PRs** — one to enable it, one to fix the apply matrix order. See [Incident 3](incidents.md#incident-3--ram-cross-org-sharing-requires-explicit-enablement-and-correct-apply-order).
- **Control Tower UI showed stale state** — API reported IN_SYNC, UI still showed drift. Hard-refresh fixed it. See [Incident 4](incidents.md#incident-4--control-tower-ui-stale-after-landing-zone-update).
- **Cross-account `kms:Decrypt` denied with the default AWS-managed key** — forced migration to a customer-managed KMS key with `aws:PrincipalOrgID` key policy. See [Incident 5](incidents.md#incident-5--cross-account-kmsdecrypt-denied-with-the-awss3-default-key).
- **State bucket CMK scheduled for deletion by CI apply** — local apply from an unmerged branch created state drift that CI later "corrected" by destroying the CMK. Recovered in ~15 minutes within the KMS grace window. See [Incident 6](incidents.md#incident-6--state-bucket-cmk-scheduled-for-deletion-by-ci-apply).

The lesson that threads through all six: **the value of this project is not that it's perfect — it's that the path from imperfect to working is visible and audit-able in git history, in runbook updates, and in the incidents log.**

## Trade-offs consciously made

Several decisions were made knowing they are not the production-correct answer, because production-correct answers would push the project past a single operator's budget or attention span:

- **Single NAT Gateway** — single-AZ compromise, $32/month instead of $97
- **No Interface VPC endpoints** — $131/month for 6 endpoints in 3 AZs is more than the three-NAT HA configuration, not justified for lab traffic volume
- **Karpenter on Fargate** — eliminates the always-on managed node group ($30/month minimum) by running Karpenter itself on pay-per-second Fargate
- **ECR over Docker Hub** — $0.50/month storage vs. Docker Hub anonymous rate limits of 100 pulls per 6 hours, which Karpenter-driven node scaling can hit trivially
- **ACM over cert-manager** — free certificates, no internet egress from cluster, one less CRD-based operator to maintain
- **Pod Identity deferred in favor of IRSA** — IRSA has better tooling maturity today; migration path to Pod Identity is a Phase 5 backlog item
- **AFT code maintained but not deployed** — Path B in ADR-011; the unused path stays fresh via CI validation

Each appears in an ADR's *Alternatives Considered* or *Consequences* section, with the reasoning on record. None were defaults accepted by accident.

## What this would look like at scale

If this architecture were deployed for a real organization instead of a lab, the ADRs flag where the trade-offs flip. The scaling path is already documented; it is not an afterthought:

- **Three NAT Gateways**, one per AZ, for AZ-independent egress (flagged in ADR-012 as the production default)
- **Interface VPC endpoints** for high-volume AWS services: STS, CloudWatch Logs, ECR API. Amortizes the fixed per-endpoint hourly cost across sustained traffic
- **AFT pipeline activated** — Path B from ADR-011 becomes the default account provisioning mechanism
- **Per-layer granular IAM** for cross-account state access, replacing the current `aws:PrincipalOrgID` condition with per-environment IAM path conditions
- **S3 access logging** on the state bucket (ISO 27001 Annex A.8.15)
- **Cross-region state replication** to the DR region (`eu-west-1`)
- **Per-team OU split** with team-scoped SCPs, once multiple teams exist
- **cert-manager** installed once service mesh mTLS or in-cluster TLS termination creates an actual requirement

Every one of these is either an *Alternatives Considered* entry, a *Future Hardening* section, or a *Consequences* paragraph in the relevant ADR. The document trail scales with the project.

## What I would do differently

These are honest retrospectives, not false-modesty performances:

- **Start with `.github/workflows/` from day one.** Phase 1 work was done through local `terraform apply` commands. Moving to PR-based CI/CD in Phase 2 was strictly better. The lesson: if PR-based flow is the end state, it should be the start state too. Starting earlier would have caught the management/shared/ipam apply-order issue before it became a production incident in PR #7.
- **Write ADRs as decisions are being made, not in batches after the fact.** ADRs 001–009 were written together after key decisions had already crystallized. ADRs 010–013 were written *during* the decision process and are noticeably sharper — the "Alternatives Considered" sections are more specific because I could see the alternatives in real time, not reconstruct them later.
- **Use the `gh` CLI from the start.** Every `gh api` command in the runbook is replayable by a future operator. Every "click Settings → Branches → Add rule" in an earlier draft was not. The runbook is more useful the further it leans on CLI commands instead of console navigation.
- **Put LICENSE in the first commit.** The project was a public repo for several PRs before it had a license. This was an inconsistency with the "real OSS project" framing introduced later.

## What this project demonstrates

For a technical reviewer reading this repository as part of an evaluation:

- **Senior-level architectural decision-making** — every load-bearing choice is explicit, reasoned, with alternatives rejected on record
- **Cost-consciousness at lab scale with an articulated scaling path to production**
- **Zero-credential security posture** — enforced by SCP at organization level, not just by policy
- **Documentation-first discipline** — 13 ADRs, 10-part runbook, 5-diagram architecture document, explicit drift policy
- **Real infrastructure, not a tutorial** — six real AWS accounts, state in S3 with native locking, CI that actually applies to AWS via OIDC
- **Operational discipline** — signed commits required, branch protection with required status checks, admin bypass for documented legitimate cases, explicit teardown strategy
- **Self-correcting process** — the main branch's git history contains real mistakes with their fixes (KMS policy, RAM sharing, apply order, stale UI state). This is a feature, not a gap. A repository with no commit-history mistakes is either trivial or pretending.

That last point is worth repeating in interview context. **The value of this project is not that it is perfect. The value is that the path from imperfect to working is visible and audit-able.** Every gotcha is documented. Every fix is in a PR. Every ADR trace is a decision that could have gone the other way.
