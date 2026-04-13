# Contributing

Thanks for taking the time to look at this repository. Before opening an issue or a PR, please read this whole file.

## Project scope

This project targets **single-operator labs and small-team deployments**. It is an opinionated reference implementation, not a general-purpose framework. If you need enterprise-scale features — multi-tenant SaaS controls, custom Config rules for complex audit frameworks, complex team-level OU splits — please use:

- [AWS Landing Zone Accelerator](https://github.com/awslabs/landing-zone-accelerator-on-aws) for AWS-native enterprise coverage
- [Gruntwork Reference Architecture](https://gruntwork.io/reference-architecture) for a commercially supported option

Scope boundaries are documented in [ADR-001](docs/decisions/001-landing-zone-scope-boundary.md). Changes that require expanding scope need an accompanying ADR that supersedes or extends ADR-001.

## What contributions are welcome

- **Bug reports** — something does not work as documented
- **Documentation fixes** — diagram or runbook drifted from reality, typos, unclear prose
- **Scope-aligned enhancements** — small features that serve the single-operator use case better
- **Security findings** — use Private Vulnerability Reporting, not a public issue (see [SECURITY.md](SECURITY.md))

## What contributions will likely be declined

- Enterprise features outside the scope boundary (listed above)
- Feature flags / configuration toggles that make a design principle opt-out
- Changes that violate a design principle (see README) without a new ADR justifying the shift

## Development workflow

1. **Open an issue first** if the change is non-trivial. Describe the use case. This saves everyone time.
2. **Fork and branch** — create a branch from `main` with a descriptive prefix (`feat/`, `fix/`, `docs/`).
3. **Read the relevant ADRs** before making decisions that touch their territory.
4. **Follow the design principles** listed in the [README](README.md#design-principles).
5. **Add or update an ADR** if you are making a load-bearing decision (something a future reader would need to understand).
6. **Update affected documentation** in the same PR — README, `docs/architecture.md`, runbooks. Drift is a bug per the project's stated policy.
7. **Open a PR** against `main`. The PR template ([`.github/pull_request_template.md`](.github/pull_request_template.md)) guides what is expected.
8. **CI must pass** — 5× Terraform Plan + Checkov. Required by branch protection, not waivable.
9. **Commits must be signed** — SSH or GPG, verified by GitHub. Required by branch protection.

## ADR process

Architecture Decision Records live in `docs/decisions/NNN-title.md`. The required sections are:

- **Status** — `Accepted`, `Superseded by NNN`, or `Deprecated`
- **Context** — what problem are you solving, what constraints exist
- **Decision** — what you chose, specifically
- **Alternatives Considered** — what you rejected and why
- **Consequences** — trade-offs accepted, what becomes easier, what becomes harder

If your change conflicts with an existing ADR, **supersede it**: update the old ADR's Status to `Superseded by NNN` and write the new ADR explaining the shift. Do not silently override.

Numbering is sequential, zero-padded (001, 002, ...). The next available number can be found by sorting `docs/decisions/`.

## Code style

- **Terraform**: `terraform fmt` is enforced by the pre-commit hook. Resource names use `snake_case`. Prefer descriptive over abbreviated names (`deny_non_eu_regions`, not `dne`).
- **Shell scripts**: `set -euo pipefail` at the top. Validate inputs. Keep scripts self-contained — no sourcing shared libraries.
- **Markdown**: match the existing tone. Prefer full sentences over bullet lists when explaining reasoning. Bullets are for lists of equivalent items.
- **Mermaid diagrams**: keep nodes minimal, annotations sparse. If a diagram needs more than ~10 nodes, split it.

## Commit messages

Follow Conventional Commits loosely:

- `feat: ...` — new capability or resource
- `fix: ...` — correction to something that was wrong
- `docs: ...` — documentation-only change
- `refactor: ...` — code reorganization without behavior change
- `test: ...` — test-only change (limited use in this project)
- `chore: ...` — dependency updates, tooling tweaks

Keep the first line under 72 characters. Body explains *why*, not *what* — the diff shows what changed.

## Reviewing PRs (for maintainers)

- Does CI pass? If not, fix CI before reviewing code.
- Does the PR touch a documented decision? Is the ADR updated?
- Does the change introduce drift between code and documentation? Call it out.
- Does the PR respect the design principles?
- If the PR is security-sensitive (SCPs, IAM, OIDC, state bucket), explicitly note that a second pair of eyes would be ideal even if not strictly required by branch protection.
