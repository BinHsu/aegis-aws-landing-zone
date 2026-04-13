# Security Policy

## Supported versions

This project is a reference implementation, not a released product. Only the `main` branch is supported.

## Reporting a vulnerability

If you discover a security vulnerability in this repository, please **do not open a public issue**.

Use GitHub's [Private Vulnerability Reporting](https://github.com/BinHsu/aegis-aws-landing-zone/security/advisories/new) to submit the report. The maintainer will acknowledge within 48 hours. Fixes are prepared in a private branch and disclosed publicly only after the fix is deployed.

## Security controls in this repository

This project enforces defense-in-depth controls at multiple layers. A security finding here means one of these controls failed:

- **Zero static credentials** — IAM Identity Center for humans, OIDC federation for CI, IRSA for workloads (planned). No IAM users, no access keys. Enforced by SCP `deny-iam-user-creation`, not just IAM policy.
- **Signed commits required on `main`** — every commit is cryptographically signed with a key the author controls. Required by branch protection.
- **Branch protection** with 5 required status checks (Terraform plan × 4 environments + Checkov). No direct pushes to `main`.
- **Admin bypass allowed but logged** — single-operator workflow; every bypass appears in GitHub's branch protection events.
- **IaC security scanning** — Checkov runs on every PR with a triaged skip list. New findings fail the build; documented skips require inline justification. See [`.github/workflows/checkov.yml`](.github/workflows/checkov.yml).
- **Schema validation on the configuration contract** — JSON Schema enforced by pre-commit hook. Blocks invalid config before commit.
- **State encryption at rest** — S3 state bucket with SSE-KMS (AWS-managed key), versioning, 30-day noncurrent version retention. Cross-account access restricted to the AWS Organization via `aws:PrincipalOrgID` condition. See [ADR-003](docs/decisions/003-terraform-backend-bootstrap.md).
- **ISO 27001:2022 Annex A alignment** — controls mapped in [ADR-005](docs/decisions/005-compliance-framework-iso-27001.md) and cited in SCP Terraform comments.

## Responsible disclosure

If you are a security researcher testing AWS resources described in this repository, note that the live deployment is a personal lab environment belonging to the author. Active testing (scanning, credential stuffing, privilege escalation attempts) against the AWS accounts referenced in ADRs is **not authorized**. Please report findings through Private Vulnerability Reporting instead of attempting live exploitation.

## Secrets handling

- No real secrets are committed to this repository. Account IDs, Organization IDs, ARNs, and SSO URLs are metadata, not secrets (see [CLAUDE.md — Security](CLAUDE.md) for the full classification).
- The only secret that exists is `LANDING_ZONE_CONFIG` — an encrypted GitHub secret containing the contents of `config/landing-zone.yaml` so CI workflows can write it to the runner. See [`scripts/configure-github.sh`](scripts/configure-github.sh).
- If you discover a real secret (access key, private key, password) committed to this repository, report it immediately via Private Vulnerability Reporting and assume it is compromised.
