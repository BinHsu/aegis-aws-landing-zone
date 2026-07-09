# ============================================================================
# One-time adoption (security account cold-start) of the resources this
# bootstrap layer manages, in case they were seeded outside Terraform.
#
# WHY: `security/bootstrap` is a BRAND NEW Terraform environment (#303) — the
# account has never had Terraform managing it. The normal cold-start path is
# a first LOCAL `terraform apply` under break-glass credentials (see the PR
# body for #303 / issue #303's manual-seed runbook), which CREATEs all nine
# resources below fresh — no import needed.
#
# This file exists as the ESCAPE HATCH for the other case: an operator who
# manually pre-created the resources (console/CLI, or a local `terraform
# apply` under AWSControlTowerExecution whose state was then discarded)
# before Terraform's S3 backend ever ran in this account — e.g. to unblock
# CI faster. A plain `terraform apply` against the (empty) S3 state would
# then fail EntityAlreadyExists trying to CREATE a resource that already
# exists. These config-driven import blocks ADOPT the existing resources
# into state instead. After import, apply UPDATEs each resource in place to
# match the declared config (a no-op if the live resource already matches) —
# no recreate, no manual `terraform import` / state surgery. Same precedent
# as prod/bootstrap's iam-survivor-import.tf (#278) and #15
# (oidc-github-apply-deployment-role.tf in the deployment account).
#
# SCOPE: covers all nine resources this layer creates in a member account —
# the account alias, the GitHub OIDC provider, the ADR-020 CI permissions
# boundary policy, the three gh-tf-*/aegis-emergency-* roles, and their three
# inline role policies. The role policies
# are Put*-idempotent (PutRolePolicy upserts, no EntityAlreadyExists) so they
# are technically safe to leave un-imported, but importing them too avoids a
# spurious "will be created" noise in the first plan/apply against adopted
# roles.
#
# GATE: the import is TOGGLEABLE, OFF by default, gated on
# var.adopt_seeded_iam_roles via a for_each toggle: when false (the normal
# fresh-account path), toset([]) generates no import block; when true, each
# block adopts its survivor.
#
# ONE-TIME: set var.adopt_seeded_iam_roles=true only for a security-account
# apply where these resources were hand-seeded ahead of Terraform. Once this
# account's bootstrap state reflects them (adopted or freshly created),
# REMOVE this file and the variable in a later cleanup PR — an import block
# whose target is already in state is a no-op, so leaving it is harmless but
# it has served its single purpose.
# ============================================================================

# ---- IAM roles --------------------------------------------------------------
# Role name = import id for aws_iam_role. Each `to` address is confirmed
# present in this layer (aegis-emergency-role.tf / oidc-github-baseline-
# role.tf / oidc-github-plan-role.tf).

# break-glass recovery role (ADR-015 OQ-1)
import {
  for_each = var.adopt_seeded_iam_roles ? toset(["break_glass"]) : toset([])
  to       = aws_iam_role.aegis_emergency_break_glass
  id       = "aegis-emergency-break-glass"
}

# baseline apply role for terraform-apply-baseline.yml (ADR-014)
import {
  for_each = var.adopt_seeded_iam_roles ? toset(["apply_baseline"]) : toset([])
  to       = aws_iam_role.gh_tf_apply_baseline
  id       = "gh-tf-apply-baseline"
}

# read-only plan role for terraform-plan.yml on PRs (ADR-014)
import {
  for_each = var.adopt_seeded_iam_roles ? toset(["plan"]) : toset([])
  to       = aws_iam_role.gh_tf_plan
  id       = "gh-tf-plan"
}

# ---- IAM inline role policies -----------------------------------------------
# Import id shape for aws_iam_role_policy is "ROLE_NAME:POLICY_NAME" — both
# halves read verbatim off the `name` / `role` arguments in each resource
# (aegis-emergency-role.tf / oidc-github-baseline-role.tf / oidc-github-plan-
# role.tf). Not strictly required (PutRolePolicy upserts, no
# EntityAlreadyExists) but importing keeps the first plan clean.

import {
  for_each = var.adopt_seeded_iam_roles ? toset(["break_glass_policy"]) : toset([])
  to       = aws_iam_role_policy.aegis_emergency_break_glass
  id       = "aegis-emergency-break-glass:emergency-break-glass-scoped"
}

import {
  for_each = var.adopt_seeded_iam_roles ? toset(["apply_baseline_policy"]) : toset([])
  to       = aws_iam_role_policy.gh_tf_apply_baseline
  id       = "gh-tf-apply-baseline:apply-baseline-scoped"
}

import {
  for_each = var.adopt_seeded_iam_roles ? toset(["plan_policy"]) : toset([])
  to       = aws_iam_role_policy.gh_tf_plan
  id       = "gh-tf-plan:plan-readonly"
}

# ---- Account-global singletons ----------------------------------------------
# Unlike the roles above, these three import ids are NOT stable literals
# across accounts — they must resolve per-account, so each uses a dynamic or
# per-account-config expression rather than a hardcoded string shared with
# another environment's copy of this file.

# GitHub OIDC identity provider (oidc-github.tf). Import id is the provider
# ARN, which embeds this account's id — resolved via the `data.aws_caller_
# identity.current` already declared in main.tf, so no new data source is
# needed. The provider "path" segment reuses `local.github_oidc_url`
# (oidc-github.tf) via the same `replace(..., "https://", "")` idiom the
# trust policies already use, so it can never drift from the resource's own
# `url` argument.
import {
  for_each = var.adopt_seeded_iam_roles ? toset(["oidc_provider"]) : toset([])
  to       = aws_iam_openid_connect_provider.github
  id       = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(local.github_oidc_url, "https://", "")}"
}

# ADR-020 CI permissions boundary policy (ci-permissions-boundary.tf), attached
# as permissions_boundary on the gh-tf-* roles above. Import id is the policy
# ARN, which embeds this account's id — reuses `local.ci_boundary_arn` already
# declared in that file so it can never drift from the resource's own `name`
# argument. Must exist before the roles that carry it (runbook 002 §4);
# closes the gap where the hand-seed escape hatch would otherwise hit
# EntityAlreadyExists on this policy (runbook 002 Gotchas).
import {
  for_each = var.adopt_seeded_iam_roles ? toset(["ci_boundary"]) : toset([])
  to       = aws_iam_policy.ci_boundary
  id       = local.ci_boundary_arn
}

# IAM account alias (main.tf). Import id is the alias string itself; this
# reuses the exact literal `aws_iam_account_alias.this` is configured with
# in main.tf for this account.
import {
  for_each = var.adopt_seeded_iam_roles ? toset(["account_alias"]) : toset([])
  to       = aws_iam_account_alias.this
  id       = "binhsu-aegis-security"
}
