# 001. Landing Zone Scope Boundary

## Status
Accepted

## Context
A landing zone can expand indefinitely. AWS Organizations, SCPs, Identity Center, networking, compute, observability, security services, compliance frameworks — each is its own multi-month project at enterprise scale. Without an explicit scope boundary, a portfolio-sized lab will either drift into incomplete coverage of too many areas, or exhaust its budget and time on foundational infrastructure before reaching the parts that demonstrate the hands-on skills it was built to showcase.

This ADR defines what is in scope and out of scope for the `aegis-aws-landing-zone` project, plus two architectural principles that constrain every subsequent decision: the management account boundary and the reproducibility requirement.

## Decision

**In scope:**

- Multi-account AWS Organizations setup via Control Tower with Terraform extensions (see ADR-008).
- A simplified AWS Security Reference Architecture OU structure (see ADR-006).
- Service Control Policies for region restriction, service guardrails, and compliance enforcement.
- AWS Identity Center with role-based permission sets as the sole human identity mechanism.
- GitHub OIDC federation as the sole machine identity for CI/CD — no long-lived IAM keys anywhere.
- Terraform infrastructure-as-code with layered state following the Terraservices pattern (see ADR-003).
- GitHub Actions CI/CD with plan-on-PR and apply-on-merge workflows.
- EKS cluster with Karpenter for node autoscaling (Phase 3).
- ArgoCD for GitOps-based application delivery (Phase 3).
- Prometheus and Grafana for observability (Phase 4).
- CloudTrail, AWS Config, and GuardDuty for security baseline (Phase 4).
- ISO 27001 compliance mapping as the project's north star (see ADR-005).

**Out of scope:**

- Root account hardening (hardware MFA, break-glass IAM user, offline credential storage). Handled externally per explicit operator decision. This is not a gap in awareness — the expansion path for a production environment is recorded as a future runbook.
- Full AWS Security Reference Architecture OU structure, specifically the `Sandbox`, `PolicyStaging`, `Suspended`, `Exceptions`, and `Deployments` OUs. Over-engineered for a six-account lab. Documented as a future expansion path in ADR-006.
- Multi-region active-active workload deployments. The primary-plus-DR strategy in ADR-002 supports failover but not active-active.
- On-premises integration, VPN, or hybrid cloud connectivity.
- Enterprise-scale Control Tower customizations via Customizations for Control Tower (CfCT).

**Management account boundary:** The management account hosts only AWS Organizations, Service Control Policies, AWS Identity Center, and Billing. It does not host workloads, Terraform state buckets, CI runners, shared ECR, or any other resource. This is a hard rule enforced by the absence of any Terraform environment named `management/<layer>/` beyond a minimal `bootstrap` baseline.

**Reproducibility requirement:** Any user with AWS credentials and a filled `config/landing-zone.yaml` file must be able to deploy this landing zone end-to-end. No hardcoded account identifiers, no hardcoded email addresses, no hardcoded region names in committed `.tf` files. The implementation mechanism is documented in ADR-004.

## Alternatives Considered

**Hand-roll AWS Organizations from scratch without Control Tower.** Rejected. This would provide negligible learning value for an operator with five years of existing AWS Organizations experience, and would consume weeks of project time that should instead be spent on GitHub Actions, ArgoCD, OIDC federation, and Karpenter — the actual learning gaps. See ADR-008 for full reasoning.

**Flat account structure with no OU hierarchy.** Rejected. SCPs attach at the OU level and inherit to member accounts. A flat structure forces per-account SCP attachment, which scales poorly and creates operational risk when new accounts are added.

**Fully out-of-the-box Control Tower with no Terraform extensions.** Rejected. This would leave nothing visible in the git repository for portfolio review. The portfolio value of the project depends on having committed, reviewable infrastructure-as-code.

## Consequences

Scope creep is prevented by the explicit boundary. When a reviewer or the operator considers adding a new feature, the first question becomes "does this fit the in-scope list, or does it belong in a future phase?"

The reproducibility requirement forces config-as-contract discipline from day one. No expedient hardcoding is permitted even during early bootstrap. This has a small up-front cost — every value must be parameterized — and a large long-term benefit: the landing zone becomes a fork-and-deploy artifact.

The management account restriction enforces blast-radius discipline. When a reviewer asks "why is your Terraform state bucket not in the management account?", the answer is "because management accounts must only host Organizations, SCPs, Identity Center, and Billing — anything else violates the blast radius principle documented in ADR-001." This is the kind of answer that separates senior architects from mid-level ones.

The interview answer for "why no root hardening" becomes offensive rather than defensive: "Out of scope by explicit decision, handled externally. In a production environment I would add hardware MFA, a break-glass IAM user with offline credentials, and SCPs preventing root user API access. The scope boundary is documented in ADR-001." This is substantially stronger than a junior-level "I didn't get to it."
