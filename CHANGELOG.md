# Changelog

All notable changes to `aegis-landing-zone-aws` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/);
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

Post-v1.0.0 changes on `main`. All changes are to the **account-fabric** scope
(ADR-017: platform tier is now `aegis-platform-aws`).

### Added

- **Deployments OU + `aegis-deployment` account** (ADR-018): seventh AWS account
  vended via Control Tower; dedicated OU for the shared release-artifact registry.
  Bootstrap layer (OIDC provider, `gh-tf-plan/apply`, break-glass role) wired into
  the plan/apply CI matrix. (#248, #259)
- **Budgets under IaC** (ADR-019): AWS Budgets resources brought into Terraform;
  daily $10 / monthly $30 alerts enforced at the management-account level; OIDC
  trust condition hard-fails when `github.infra_repo_id` is unset. (#258, #259)
- **`prod` bootstrap** wired into CI plan + apply matrices post role-seed. (#241, #242)
- **SCP ACK IAM carve-out**: deny-iam-privilege-escalation SCP carved out the ACK
  IAM controller role; enforced ARN prefix documented and corrected. (#230, #239, #243)
- **CodeRabbit quality gate** enabled: request-changes + pre-merge checks on every PR. (#250)
- **All GitHub Actions SHA-pinned** across the workflow matrix. (#269)
- **Cross-repo portfolio navigation** and docs nav added to README. (#268)
- **OpenSSF Scorecard** workflow (`scorecard.yml`) — weekly + on push to main;
  SARIF uploaded to GitHub Security; badge on README.
- **Community health**: `CODE_OF_CONDUCT.md` (Contributor Covenant v2.1).
- **Evidence sample**: `docs/evidence/oidc-assumerole-sample.md` — redacted
  `AssumeRoleWithWebIdentity` CloudTrail record proving OIDC federation behaviour.

### Changed

- **ADR-017** recorded: platform-tier extraction retroactively documented; phantom
  "ADR-033" citation corrected to ADR-017 in the v1.0.0 release body.
- **ADR-018 Accepted**: Deployments OU graduated from Proposed after account vend.
- **ADR-019 Accepted**: Budgets-as-IaC + fail-closed OIDC trust.
- Vocabulary alignment: `teardown` → `destroy`, `cold-apply` → `bootstrap`,
  `decommission` → `destroy` across docs and runbooks. (#229)
- Repo self-references corrected: `aegis-aws-landing-zone` → `aegis-landing-zone-aws`;
  `aegis-platform` → `aegis-platform-aws`. (#238, #240)

### Fixed

- OIDC trust fails closed when `github.infra_repo_id` is unset — previously the
  condition silently passed (ADR-019). (#258)
- `gh-tf-apply-baseline` role now permitted to delete service-linked roles. (#227)
- SCP ACK IAM carve-out prefix corrected (was missing the leading `"aws"`). (#243)

---

## [1.0.0] — 2026-05-18

First stable release. Freezes the repository at its **broad-scope** shape,
immediately before the account-fabric descope (ADR-017).

### Added

- **7-account AWS Organization** under a simplified AWS SRA OU structure —
  `management`, `security`, `logarchive`, `shared`, `staging`, `prod`,
  `deployment` — using Control Tower + Terraform hybrid (ADR-006, ADR-008).
- **Service Control Policies**: region restriction (eu-central-1 primary /
  eu-west-1 DR) + service guardrails including deny-iam-user-creation and
  deny-iam-privilege-escalation.
- **Zero static credentials** design: AWS IAM Identity Center for humans,
  GitHub OIDC federation for CI — no IAM users (enforced by SCP, ADR-014).
- **Terraform ≥ 1.10** with S3 native state locking; no DynamoDB;
  Terraservices-pattern state layout (ADR-003).
- **GitHub Actions GitOps pipeline**: plan-on-PR, apply-on-merge (baseline auto /
  workload gated), Checkov IaC security scan, all required status checks.
- **Centralized IPAM** with RAM cross-account sharing — org-wide, collision-free
  CIDR authority (ADR-012).
- **Account-fabric security baseline**: organizational CloudTrail, AWS Config,
  GuardDuty, and a layered IAM scope-down ladder (ADR-014–016).
- **Fork-and-deploy** configuration contract (ADR-004): one YAML file +
  `configure-backends.sh` + `configure-github.sh`.
- **19 ADRs** (`001`–`019`), covering every load-bearing design decision.
- **Operational runbook** (`docs/runbooks/001-bootstrap-aws-account.md`):
  step-by-step from zero AWS account to SSO-authenticated CLI.
- **Incident postmortems** (`docs/incidents.md`): real failures, written after
  the fact, never softened retroactively.
- **Signed commits enforced** via branch protection + SSH-key signing.
- **Pre-commit hook** for JSON Schema validation of `config/landing-zone.yaml`.

### Changed

- ADR-017 enacted (retroactively documented post-release): platform tier
  extracted to `aegis-platform-aws`; landing zone descoped to account fabric only.

---

[Unreleased]: https://github.com/BinHsu/aegis-landing-zone-aws/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/BinHsu/aegis-landing-zone-aws/releases/tag/v1.0.0
