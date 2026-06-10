# 019. Budgets Are IaC and the OIDC Trust Fails Closed

## Status

Accepted (2026-06-10).

Note on numbering: 018 is allocated to the Deployments-OU ADR on the open
`feat/adr10-deployments-ou-and-account` branch (PR #248); this ADR takes the
next free number to avoid a collision when both land.

## Context

Two findings from the same review, both instances of the same failure class:
a control whose *documented* posture and *actual* posture diverge.

### 1. The only guardrail that ever fired was not under version control

Runbook 001 §3.5 creates two budgets in the management account by console
click-path — `aegis-daily-usd10` (daily, $10) and `aegis-monthly-usd30`
(monthly, $30). No `aws_budgets_budget` resource existed anywhere in this
repository.

In the 2026-06-06 cost incident (an EKS cluster on extended support left
running for ~3 days in the prod account; postmortem in the platform repo,
`docs/postmortems/2026-06-06-*`), the org daily budget alarm was the **only**
guardrail that fired. The single control that demonstrably works was:

- not reproducible — a forker following only the Terraform gets no budgets;
- not drift-protected — a console deletion would be silent and permanent;
- not reviewable — its thresholds and recipients lived in nobody's diff.

The same postmortem flagged that the member accounts `aegis-staging`,
`aegis-shared`, and `aegis-logarchive` carried **no per-account budget at
all** — a runaway in any of them is visible only after it moves the org-wide
aggregate.

### 2. The CI OIDC trust silently fails open without `infra_repo_id`

ADR-014/015 restructured the `gh-tf-plan` / `gh-tf-apply-baseline` trust
policies to be rename-proof: the `sub` claim is checked with `StringLike
repo:<org>/*:ref:refs/heads/main` (repo name deliberately wildcarded), and the
real repository binding is a `StringEquals` condition on the immutable
`repository_id` claim. That binding is merged into the policy **only when**
`github.infra_repo_id` is set in `config/landing-zone.yaml`:

```hcl
github_infra_repo_id = try(local.config.github.infra_repo_id, null)
github_oidc_infra_repo_id_claim = local.github_infra_repo_id != null ? { ... } : {}
```

If a forker omits the key, nothing fails — Terraform happily creates a trust
policy whose only repo constraint is the owner-wide wildcard. Any repository
under that GitHub owner can then mint a `refs/heads/main` token and assume
`gh-tf-apply-baseline` in every account. The example config made it worse by
documenting a safety net that does not exist: "If unset, OIDC trust policies
fall back to repo full_name pinning only" — there is no full-name pinning
anywhere in the trust policies.

## Decision

### A. Budgets are Terraform resources

- `terraform/environments/management/bootstrap/budgets.tf` declares the two
  org-wide budgets. Daily keeps the runbook's single **80%-of-actual** alert;
  monthly — where the runbook used a console template and pinned no
  thresholds — standardizes on **80% + 100% of actual**. Recipients are
  `budget.alert_emails` from the config contract (ADR-004).
- Because both budgets already exist in the live account, `import` blocks
  (Terraform >= 1.5; this repo requires >= 1.10) with id
  `<management-account-id>:<budget-name>` adopt them on the first apply
  instead of colliding. The account id is derived from config
  (`local.account_id`), never hardcoded. The blocks become no-ops after
  adoption and assume runbook 001 §3.5 ran first — which it always does,
  since §3.5 precedes the first `terraform apply` in the bootstrap sequence.
- New per-account **$10 monthly** budgets (80% + 100% actual, same
  recipients): `staging/bootstrap` and `shared/bootstrap` each carry their
  own; `aegis-logarchive` gets a `LinkedAccount`-filtered budget in
  `management/bootstrap` because that Control-Tower-managed account has no
  Terraform environment of its own. The amount is the optional config key
  `budget.member_monthly_usd` (default 10).
- The `gh-tf-apply-baseline` roles in management / staging / shared gain a
  `BudgetsScoped` statement (`budgets:*` on
  `arn:aws:budgets::<account>:budget/aegis-*`); the `gh-tf-plan` roles gain
  the budgets read shapes. All three layers are already in the CI plan and
  apply matrices — no workflow change.

### B. `github.infra_repo_id` is required — the trust fails closed

- Every bootstrap environment's `aws_iam_openid_connect_provider.github`
  carries a `lifecycle.precondition` that fails the plan when
  `infra_repo_id` is unset, with the remediation in the error message
  (`gh api repos/<owner>/<repo> --jq .id`). The provider is the resource every
  `gh-tf-*` role trust references, so gating it gates the whole trust chain.
- `config/schema.json` adds `infra_repo_id` to the `github` required list, so
  `make validate-config` (`scripts/validate-config.py`) fails before Terraform
  does. The Terraform precondition remains authoritative — CI's apply path
  does not run the schema validator.
- The false "full_name pinning" comment in `config/landing-zone.example.yaml`
  is replaced with the real behavior.

## Alternatives Considered

- **Keep budgets console-managed, document harder.** Rejected: documentation
  was the status quo that failed. The incident proved the budget is
  load-bearing; load-bearing controls live in version control.
- **A dedicated `management/budgets` Terraform environment.** Rejected: a new
  state key, backend block, CI matrix rows, and IAM surface for three small
  resources. The bootstrap layer is the established home for account-level
  baseline (alias, OIDC, detective controls); budgets are the same tier.
- **Create a `logarchive/bootstrap` environment for its budget.** Rejected:
  that would mean scaffolding an OIDC provider, two CI roles, and state
  wiring in a Control-Tower-managed account to hold one budget. The
  `LinkedAccount` cost filter from the payer account is the same control for
  none of the cost.
- **Centralize ALL member budgets in the management account.** Viable (the
  payer sees every linked account), but staging and shared already have
  bootstrap layers and apply roles; keeping each account's guardrail in the
  account's own baseline keeps the layer self-describing and the payer-account
  policy minimal. Logarchive is the exception, by necessity.
- **Leave `infra_repo_id` optional but warn (a `check` block).** Rejected:
  `check` blocks emit warnings, and a warning in a green CI run is invisible —
  that is the exact silent-fail-open this fixes. Fail closed means a hard
  plan error.
- **Schema-only enforcement of `infra_repo_id`.** Rejected as the sole gate:
  the CI apply path writes the config from a secret and runs Terraform
  directly, never the schema validator. The precondition sits where the
  resource is created.

## Consequences

- **Adoption is two-step, by necessity.** An `import` block makes `terraform
  plan` call `budgets:DescribeBudget` at plan time, but the permission that
  allows it ships in the same change — the live `gh-tf-plan` role cannot read
  budgets until the baseline apply has landed the new policy. So the IAM
  permissions (plus the OIDC fail-closed change) merge first; the
  `aws_budgets_budget` resources + import blocks follow in a second PR once
  the roles carry `budgets:ViewBudget`/`Describe*`.
- The first CI apply after the second PR lands adopts the two console budgets
  via the import blocks and reconciles their notification sets to the code
  (in-place update — the monthly budget's console-template notifications
  converge to 80%/100% actual). The import blocks can be deleted in a later
  cleanup once state shows the budgets.
- Three new budgets are created (staging, shared, logarchive-filtered).
  Budget alert delivery is free; the resources are $0.
- **Forkers must set `github.infra_repo_id` before the first plan.** A fork
  that omits it gets a hard error with the `gh api` one-liner instead of an
  owner-wide trust. This is a deliberate breaking change for any fork that
  relied on the (undocumented, unsafe) fail-open path.
- A fork that skipped runbook 001 §3.5 (no console budgets) must create the
  two org budgets first or remove the import blocks — `terraform plan` fails
  on importing a non-existent remote object.
- `budget.member_monthly_usd` joins the config contract as an optional key;
  the live org's config secret needs no change (the default of 10 matches the
  decision).
- Runbook 001 §3.5 remains the day-0 path (budgets must exist before any
  Terraform runs in a fresh account); after bootstrap, Terraform owns them.

## Related

- [ADR-004](004-deployment-configuration-contract.md) — config contract the
  budget amounts and `infra_repo_id` ride on.
- [ADR-009](009-lifecycle-and-teardown-strategy.md) — cost model the $10/$30
  caps are sized against.
- [ADR-014](014-iam-permission-scope-down.md) /
  [ADR-015](015-permission-boundary-hardening.md) — the trust-policy
  restructure that introduced the `repository_id` claim this ADR makes
  mandatory.
- [ADR-016](016-detective-controls.md) — detective sibling; reuses
  `budget.alert_emails[0]` for its SNS subscription.
- Runbook [001](../runbooks/001-bootstrap-aws-account.md) §3.5 — the console
  steps the import blocks adopt.
- `docs/finops.md` — budget-cap narrative updated alongside this ADR.
