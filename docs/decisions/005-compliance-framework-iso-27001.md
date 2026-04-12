# 005. Compliance Framework — ISO 27001 Mapping

## Status
Accepted

## Context
A landing zone without a compliance reference is technically complete but strategically shallow. Every control it implements — region restriction, encryption defaults, centralized logging, role-based access — exists to satisfy some external requirement, yet without naming that requirement, the decisions look arbitrary. A landing zone with an explicit compliance north star can trace every guardrail back to a named control, which transforms it from a collection of best practices into a deliberate compliance posture.

This ADR establishes ISO 27001:2022 Annex A as the compliance reference for the project and commits to a formal mapping document cross-referencing each implementation to the control it satisfies.

## Decision

ISO 27001:2022 Annex A is the compliance north star for this landing zone.

A formal mapping document at `docs/compliance/iso27001-mapping.md` cross-references Annex A controls to concrete implementations in this repository: SCP statements, AWS Config rules, Control Tower detective and preventive guardrails, Tag Policies, KMS key policies, IAM boundary policies, and custom Kyverno admission policies added in Phase 3.

Every new guardrail added to the project must cite the Annex A control it satisfies, either in its own ADR or in the commit message that introduces it. This cross-reference is a hard rule, not a suggestion. Commit hooks check for the presence of the reference in commit messages that modify SCPs or Config rules.

The mapping document is organized by Annex A control group: organizational controls, people controls, physical controls, technological controls. Within the technological controls section — where the vast majority of infrastructure-level enforcement lives — each entry lists the AWS implementation, the configuration file or Terraform module where it lives, the OU or account it applies to, and any known gaps.

## Alternatives Considered

**SOC 2 Type II.** Rejected as the primary framework. SOC 2 Type II requires continuous audit workflow, evidence collection over an extended observation period (typically six to twelve months), and a third-party auditor attestation. None of these are achievable within a lab project. A SOC 2 mapping could be added as a secondary framework later without displacing ISO 27001.

**PCI DSS.** Rejected. PCI DSS applies only to environments handling cardholder data. This project has no cardholder data scope, so PCI DSS would be aspirational without substance.

**HIPAA.** Rejected. HIPAA applies to protected health information. This project has no PHI scope.

**NIST Cybersecurity Framework (CSF).** Considered. CSF is broader and more prescriptive than ISO 27001 Annex A in some areas, and is widely used in US organizations. It can be added as a secondary framework in a future ADR without replacing the ISO 27001 mapping. The primary framework is chosen as ISO 27001 because the operator has three years of direct operational experience with it from prior roles, making it a force multiplier rather than a learning burden.

**CIS AWS Foundations Benchmark as the framework.** Considered. CIS Foundations is technical and AWS-specific, which makes it easier to implement but narrower in scope — it does not cover organizational, people, or physical controls. It is better treated as a compliance tooling reference than as a primary framework. The mapping document includes a cross-reference column for CIS Foundations controls where applicable.

**No compliance framework, just "best practices".** Rejected. This is the default for most lab projects and is precisely what this project seeks to differentiate against. Named compliance controls are the single strongest portfolio differentiator available to an operator with ISO 27001 operational experience.

## Consequences

Every new SCP, AWS Config rule, Control Tower guardrail, KMS policy, or Kyverno admission policy requires an Annex A reference. This adds a small documentation cost per change — typically one line in a commit message or ADR — and compounds into a structured compliance posture over the project's lifetime.

Compliance posture becomes portfolio-visible. A hiring manager reading `docs/compliance/iso27001-mapping.md` sees a matrix of controls traced to implementations, which is a concrete demonstration of the operator's compliance expertise rather than a line on a resume.

Adding a secondary framework later (NIST CSF, SOC 2 Type II, CIS Foundations) is an additive operation. New cross-reference columns can be added to the mapping document without restructuring existing entries. Replacing ISO 27001 with a different primary framework would require significant rework, which is why the decision is taken early and explicitly.

The interview answer to "how did you design your SCPs?" becomes "I started from the ISO 27001 Annex A control list and asked, for each relevant control, what AWS mechanism enforces it. The answers are documented in `docs/compliance/iso27001-mapping.md` and cross-referenced from each SCP's Terraform module." This is an answer that most candidates cannot give and that directly leverages the operator's existing background.

A risk is that the mapping document can become outdated if it is treated as a one-time deliverable rather than as a living artifact. The hard rule requiring Annex A citation on every new guardrail is the mitigation: the document cannot drift silently because every contributing change must touch it.
