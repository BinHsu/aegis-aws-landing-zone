# 001. Landing Zone Scope Boundary

## Status
Accepted

## Context
A landing zone can expand indefinitely. AWS Organizations, SCPs, Identity Center, networking, compute, observability, security services, compliance frameworks — each is its own multi-month project at enterprise scale. Without an explicit scope boundary, a portfolio-sized lab will either drift into incomplete coverage of too many areas, or exhaust its budget and time before the foundation is coherent.

This ADR defines what is in scope and out of scope for the `aegis-landing-zone-aws` project, plus two architectural principles that constrain every subsequent decision: the management account boundary and the reproducibility requirement.

## Decision

This repository is the AWS **account fabric** — the organization-level foundation that every workload account is built on top of. It is deliberately bounded to that layer; cluster, application, and observability concerns belong to repositories higher in the tier model (see ADR-007).

**In scope:**

- Multi-account AWS Organizations setup via Control Tower with Terraform extensions (see ADR-008).
- A simplified AWS Security Reference Architecture OU structure (see ADR-006).
- Service Control Policies for region restriction, service guardrails, and compliance enforcement.
- AWS Identity Center with role-based permission sets as the sole human identity mechanism.
- GitHub OIDC federation as the sole machine identity for CI/CD — no long-lived IAM keys anywhere.
- Account bootstrap and vending — the per-account baseline layer plus the two account-provisioning paths (see ADR-010, ADR-011).
- Organization-wide IPAM as the single CIDR-allocation authority for every account (see ADR-012).
- The centralized security and audit baseline: organizational CloudTrail, AWS Config, and the detective controls in the management account (see ADR-016).
- Terraform infrastructure-as-code with layered state following the Terraservices pattern (see ADR-003).
- GitHub Actions CI/CD with plan-on-PR and apply-on-merge workflows.
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

**Fully out-of-the-box Control Tower with no Terraform extensions.** Rejected. This would leave nothing visible in the git repository for review. The value of the project depends on having committed, reviewable infrastructure-as-code.

## Consequences

Scope creep is prevented by the explicit boundary. When a reviewer or the operator considers adding a new feature, the first question becomes "does this fit the in-scope list, or does it belong in a future phase?"

The reproducibility requirement forces config-as-contract discipline from day one. No expedient hardcoding is permitted even during early bootstrap. This has a small up-front cost — every value must be parameterized — and a large long-term benefit: the landing zone becomes a fork-and-deploy artifact.

The management account restriction enforces blast-radius discipline. When a reviewer asks "why is your Terraform state bucket not in the management account?", the answer is "because management accounts must only host Organizations, SCPs, Identity Center, and Billing — anything else violates the blast radius principle documented in ADR-001." This is the kind of answer that separates senior architects from mid-level ones.

The interview answer for "why no root hardening" becomes offensive rather than defensive: "Out of scope by explicit decision, handled externally. In a production environment I would add hardware MFA, a break-glass IAM user with offline credentials, and SCPs preventing root user API access. The scope boundary is documented in ADR-001." This is substantially stronger than a junior-level "I didn't get to it."
