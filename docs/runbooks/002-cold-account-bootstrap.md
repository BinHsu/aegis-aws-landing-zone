# Runbook 002. Cold Account Bootstrap (Seed + Adopt)

This runbook documents how to bring up the CI bootstrap IAM roles in a brand-new
member account — the one apply that cannot run through GitHub Actions, because
GitHub Actions needs those exact roles to exist first. It supersedes an
error-message pointer to a non-existent "Runbook 001 Part 9" that shipped in
`security/bootstrap` and `logarchive/bootstrap` (Runbook 001's actual Part 9 is
*Provision Remaining Accounts (staging + prod)*, which does not cover this
procedure). Use `scripts/cold-start-bootstrap.sh` for every step below; do not
run the underlying Terraform/AWS CLI commands by hand — the script's identity
checks and traps are the safety net.

## When to use this

Any time a NEW member account gets its first Terraform bootstrap layer —
`security` and `logarchive` (#303) were the first cases, and any future member
account will hit the same chicken-and-egg on its first apply. If the
environment's Terraform code does not yet exist under
`terraform/environments/<env-dir>/bootstrap/`, this runbook does not apply yet —
scaffold the environment first (mirror an existing `bootstrap/` layer, see #303).

## The problem

### 1. Chicken-and-egg: CI needs roles that do not exist yet

Every environment's `bootstrap/` layer creates three roles GitHub Actions
assumes via OIDC — `gh-tf-plan` (read-only, on pull requests),
`gh-tf-apply-baseline` (on merge to `main`, per ADR-014) — plus
`aegis-emergency-break-glass` (ADR-015), the GitHub OIDC provider, the
account alias, and the ADR-020 `aegis-landing-zone-aws-ci-boundary`
permissions boundary policy. Nine resources in total.

CI's `terraform-plan.yml` / `terraform-apply-baseline.yml` workflows assume one
of those roles to run. On a cold account, none of them exist — CI has nothing
to assume, so the account's very first apply cannot run in CI. It has to run
from a human operator's local credentials.

### 2. The state bucket will not accept the only role a human can use

The only path a human has *into* a freshly Control-Tower-vended member account
is `AWSControlTowerExecution` (assumed from the management account). But the
Terraform state bucket's policy only grants write access to `gh-tf-*` roles,
`aegis-emergency-*` roles, and the `PlatformAdmin-SSO` permission set —
`AWSControlTowerExecution` is deliberately not on that list, so a normal
S3-backed `terraform apply` run under CT-exec fails on state access before it
ever creates a resource.

### 3. The resolution: seed with local state, then adopt into S3 state

The procedure is two phases against the same account:

- **SEED** — `terraform apply` under `AWSControlTowerExecution`, with
  `backend.tf` moved aside so state is local and throwaway. This actually
  creates the nine resources in the account. Local state is fine here
  because nothing durable needs to survive this phase — the resources
  themselves are the durable output, not the state file.
- **ADOPT** — a **split-credential** apply: the Terraform **backend**
  authenticates as the operator's ambient `PlatformAdmin` profile (who *can*
  write the S3 state bucket), while the Terraform **provider** (the thing that
  actually talks to the target account's resources) temporarily assumes
  `AWSControlTowerExecution` via a generated override file. Run with
  `-var=adopt_seeded_iam_roles=true`, which flips the environment's
  `iam-survivor-import.tf` from *create* to *import* for the nine resources
  SEED just created — so ADOPT's plan is exactly nine imports and (ideally)
  no other changes.

After ADOPT, the S3 state matches reality. The committed default of
`var.adopt_seeded_iam_roles` is `false`, so the next ordinary CI apply
(`gh-tf-apply-baseline`, real S3 state, `adopt_seeded_iam_roles=false`) plans
against the now-populated state and shows no changes — green, with zero manual
steps from that point on.

This is the same precedent as `prod/bootstrap`'s `iam-survivor-import.tf`
(#278) and the `deployment` account's
`oidc-github-apply-deployment-role.tf` (#15); `security`/`logarchive` (#303)
are simply the first pair of accounts where the seed+adopt ceremony had to run
against a truly cold account rather than one break-glass-created resource.

### 4. ADR-020: the boundary must exist before the CI roles that carry it

ADR-020 (PR-1) added the `aegis-landing-zone-aws-ci-boundary` permissions
boundary to every `*/bootstrap` layer and set `permissions_boundary` on all
three `gh-tf-*`/`gh-tf-apply-*` roles. Two consequences for cold-start:

- **Ordering within the seed apply is automatic.** The seed layer now creates
  `aws_iam_policy.ci_boundary` too, and each `gh-tf-*` role references
  `aws_iam_policy.ci_boundary.arn`, so Terraform creates the boundary *before*
  the roles inside the same apply. No manual pre-create is needed on the normal
  path. `aegis-emergency-break-glass` is deliberately **not** bounded (it is the
  boundary's own in-account repair path — ADR-020 D3).
- **Post-PR-2, the org-root SCP requires the boundary at role-create time.**
  Once ADR-020 PR-2's SCP S1 is attached at the org root, a `gh-tf-*` caller
  that runs `iam:CreateRole` without the boundary is denied
  (`DenyUnboundedRoleCreateByCi`). Cold-start is unaffected **by construction**:
  the seed runs under `AWSControlTowerExecution`, which is outside S1's
  `gh-tf-*` scope, and the boundary is created first in the same apply — so CI
  (`gh-tf-*`) only ever runs against an account that already has the boundary.
  If the boundary is somehow absent or corrupt on a fresh account, break-glass
  (`aegis-emergency-*`, exempt from S1 and from S2's `ProtectBoundaryPolicy`)
  can create or repair it with `iam:CreatePolicy` — that action is in no deny
  list.

## Prerequisites

- `aws sso login --sso-session aegis` already run.
- The target environment's Terraform code already committed at
  `terraform/environments/<env-dir>/bootstrap/`, including a
  `var.adopt_seeded_iam_roles`-gated `iam-survivor-import.tf` (see
  `terraform/environments/prod/bootstrap/iam-survivor-import.tf` for the
  pattern).
- An AWS CLI profile (default `aegis-management-admin`) that can assume
  `AWSControlTowerExecution` into the target account and holds
  `PlatformAdmin` rights against the state bucket.
- `aws` CLI v2, `jq`, `python3` with `pyyaml`, `terraform >= 1.10` on `PATH`.
- `accounts.<env-dir>.id` populated in `config/landing-zone.yaml`, or pass
  `--account-id` explicitly.

## Procedure

### Phase 0 — Boundary preflight (ADR-020)

Before seeding `gh-tf-*` roles on any cold account, create or verify the
`aegis-landing-zone-aws-ci-boundary` permissions boundary exists in the target
account. On the normal path this is automatic — the seed apply in Phase 1
creates the boundary before the roles that reference it (see "The problem" §4) —
so this step is a **verify**, not a manual create:

```
aws iam get-policy \
  --policy-arn "arn:aws:iam::<target-account-id>:policy/aegis-landing-zone-aws-ci-boundary" \
  --query 'Policy.PolicyName' --output text 2>/dev/null || echo "ABSENT — expected during Phase 1"
```

- **Absent before Phase 1**: expected on a truly cold account — Phase 1 creates
  it. Proceed.
- **Absent after Phase 1 completed**: a bug — the seed apply should have created
  it. Do not let CI (`gh-tf-*`) run against this account until it exists (post-
  PR-2, CI's first `CreateRole` would be denied `AccessDenied` by SCP S1). Repair
  via break-glass `iam:CreatePolicy` (the only identity SCP S2 exempts), then
  re-run Phase 1's converge.

Attaching the boundary to the seeded roles at seed time is hygiene, not a hard
requirement: the roles carry `permissions_boundary` in code, so Phase 1's apply
attaches it, and any later CI apply converges a boundary-less seeded role via
`iam:PutRolePermissionsBoundary` to the correct ARN — which SCP S1 allows
(ADR-020 D2).

### Phase 1 — Seed

```
./scripts/cold-start-bootstrap.sh --env-dir security --mode seed
```

The script:

1. Prints the source profile's identity, then assumes
   `AWSControlTowerExecution` into the target account and **verifies the
   assumed identity's account id matches the expected account** before
   touching any Terraform state — a typo'd `--account-id` or a stale
   `config/landing-zone.yaml` value fails here, not mid-apply.
2. Moves `backend.tf` aside (`backend.tf.seedbak`) so `terraform init` uses
   local state. The committed `.terraform.lock.hcl` is left untouched — only
   the `.terraform/` cache and any prior local state are cleared.
3. Runs `terraform plan` and shows it in full.
4. Prompts interactively: `Apply SEED to <env-dir> (<account>)? Type 'yes' to
   proceed:`. Anything other than `yes` skips the apply.
5. On confirmation, applies, lists the `gh-tf-*` / `aegis-emergency-*` roles
   now present in the account, and deletes the throwaway local state.
6. Restores `backend.tf` via a trap that fires on **any** exit — success,
   `Ctrl-C`, or an unhandled error — so the environment is never left without
   its backend.

Run this once per environment. Repeat for each new cold account (e.g. run
again with `--env-dir logarchive`).

### Phase 2 — Adopt

```
./scripts/cold-start-bootstrap.sh --env-dir security --mode adopt
```

The script:

1. Re-verifies `AWSControlTowerExecution` still resolves to the expected
   account (independent of Phase 1 — this is a separate invocation, possibly
   run later or by someone else).
2. Prints the ambient profile's identity (this is what the S3 backend will
   authenticate as).
3. Writes `cold_start_adopt_override.tf` — a Terraform **override file**
   (matches the `*_override.tf` naming convention Terraform recognizes
   specially: it *merges* into the committed `provider "aws" {}` block rather
   than declaring a conflicting second one) that adds an `assume_role` for
   `AWSControlTowerExecution`. This file is temporary and is deleted by a trap
   on any exit — it is never committed.
4. Runs `terraform init` against the real S3 backend under the ambient
   profile, then `terraform plan -var=adopt_seeded_iam_roles=true` — expect
   exactly nine imports and no other changes.
5. Prompts interactively for confirmation, same pattern as Seed.
6. On confirmation, applies (imports land in S3 state) and prints
   `terraform state list` to confirm all nine resources are now tracked.

### Both in one run

```
./scripts/cold-start-bootstrap.sh --env-dir security --mode both
```

Runs Seed immediately followed by Adopt against the same account — useful when
one operator is doing both phases back to back in a single sitting.

### Verification

After Adopt, confirm the state converges with no manual step from CI's point
of view:

```
cd terraform/environments/security/bootstrap
terraform plan   # ordinary run, adopt_seeded_iam_roles defaults to false
```

Expect **no changes**. If CI already has a PR open against this environment,
its `terraform-plan.yml` run should also show no diff once merged and
`terraform-apply-baseline.yml` runs the real (adopt=false) apply.

## Gotchas

- **Do not run Adopt before Seed.** Adopt's plan expects the nine resources
  to already exist in the account; running it first produces an empty import
  set and then a normal (failing) create attempt under the wrong credentials.
- **`--profile` must be able to do both things Adopt needs**: assume
  `AWSControlTowerExecution` into the target account, *and* hold
  `PlatformAdmin`-level rights on the shared account's state bucket. A
  narrower profile that can only do one half fails at `terraform init` or at
  the assume-role verification step, not silently.
- **A stale `cold_start_adopt_override.tf` or `backend.tf.seedbak` left in a
  bootstrap directory** (from a prior run killed with `kill -9`, which no
  trap can catch) blocks the next run. The script's own EXIT/INT/TERM trap
  cleans these up on every normal exit and on `Ctrl-C`; if one is still
  present, delete it manually before re-running.
- **Fixed: the ADR-020 boundary is now in the `iam-survivor-import.tf` gate.**
  PR-1 added `aws_iam_policy.ci_boundary` alongside the original eight
  bootstrap resources but did not extend the import gate to cover it, so the
  manual hand-seed escape hatch (`var.adopt_seeded_iam_roles=true` after
  pre-creating resources by hand) hit `EntityAlreadyExists` on the boundary.
  All three `iam-survivor-import.tf` files (`prod`, `security`, `logarchive`
  bootstrap) now carry a gated `import` block for `aws_iam_policy.ci_boundary`
  mirroring the role blocks, so Adopt's plan is exactly nine imports on every
  path, including hand-seed. Tracked as an ADR-020 PR-1 follow-up.

## Cross-references

- Issue [#309](https://github.com/BinHsu/aegis-landing-zone-aws/issues/309) /
  [ADR-021](../decisions/021-ci-native-cold-account-bootstrap.md) (**Proposed**)
  — the design to eliminate this manual ceremony with a CI-native bootstrap: a
  management-level bootstrap role that assumes into a newly-enrolled account
  *and* writes the S3 state bucket in one CI run, retiring
  `iam-survivor-import.tf` and `var.adopt_seeded_iam_roles` once cold-start no
  longer needs them. ADR-021 is not yet accepted — this runbook remains the
  live procedure until it is, and is scheduled for rewrite at ADR-021 Migration
  Stage 3. Note: "AFT-style" there means a central CI-driven bootstrap, *not*
  activating the real AFT layer (ADR-011 Path B), which automates account
  creation rather than this configuration bootstrap.
- Issue [#303](https://github.com/BinHsu/aegis-landing-zone-aws/issues/303) —
  the `security`/`logarchive` environment creation this runbook's procedure
  was first exercised against.
- `terraform/environments/prod/bootstrap/iam-survivor-import.tf` (#278) — the
  precedent for the `var.adopt_seeded_iam_roles` import-gating pattern this
  runbook's Adopt phase relies on.
- [ADR-014](../decisions/014-iam-permission-scope-down.md) — the
  `gh-tf-plan` / `gh-tf-apply-baseline` two-role OIDC trust split these
  scripts seed and adopt.
- [ADR-015](../decisions/015-permission-boundary-hardening.md) — the
  `aegis-emergency-break-glass` role.
- [ADR-020](../decisions/020-scp-enforced-ci-permissions-boundary.md) — the
  `aegis-landing-zone-aws-ci-boundary` permissions boundary (PR-1) and the
  SCP S1/S2 that force and protect it (PR-2); the source of the Phase 0
  boundary preflight above.
- [Runbook 001](001-bootstrap-aws-account.md) — the from-zero project
  bootstrap this runbook assumes is already complete (management account,
  Control Tower, state bucket, SSO).

## What's Next

With Seed and Adopt complete for an environment:

- The account's `gh-tf-plan`, `gh-tf-apply-baseline`, and
  `aegis-emergency-break-glass` roles exist and are tracked in the real S3
  state.
- CI (`terraform-plan.yml` on PRs, `terraform-apply-baseline.yml` on merge to
  `main`) can operate on this environment with zero further manual steps.
- `var.adopt_seeded_iam_roles` stays at its committed default (`false`) —
  nothing to revert; it was only ever set via `-var` for the one Adopt run.
