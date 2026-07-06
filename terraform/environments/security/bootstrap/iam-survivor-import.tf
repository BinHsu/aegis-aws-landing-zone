# ============================================================================
# One-time adoption (security account cold-start) of the IAM roles this
# bootstrap layer manages, in case they were seeded outside Terraform.
#
# WHY: `security/bootstrap` is a BRAND NEW Terraform environment (#303) — the
# account has never had Terraform managing it. The normal cold-start path is
# a first LOCAL `terraform apply` under break-glass credentials (see the PR
# body for #303 / issue #303's manual-seed runbook), which CREATEs the three
# roles below fresh — no import needed.
#
# This file exists as the ESCAPE HATCH for the other case: an operator who
# manually pre-created the three roles (console/CLI) before Terraform ever
# ran in this account — e.g. to unblock CI faster, or because AWSControl
# TowerExecution was used to hand-seed them. A plain `terraform apply` would
# then fail EntityAlreadyExists trying to CREATE a role that already exists.
# These config-driven import blocks ADOPT the existing roles into state
# instead. After import, apply UPDATEs each role in place to match the
# declared config (a no-op if the live policy already matches) — no recreate,
# no manual `terraform import` / state surgery. Same precedent as prod/
# bootstrap's iam-survivor-import.tf (#278) and #15
# (oidc-github-apply-deployment-role.tf in the deployment account).
#
# GATE: the import is TOGGLEABLE, OFF by default, gated on
# var.adopt_seeded_iam_roles via a for_each toggle: when false (the normal
# fresh-account path), toset([]) generates no import block; when true, each
# block adopts its survivor.
#
# ONE-TIME: set var.adopt_seeded_iam_roles=true only for a security-account
# apply where the roles were hand-seeded ahead of Terraform. Once this
# account's bootstrap state reflects the roles (adopted or freshly created),
# REMOVE this file and the variable in a later cleanup PR — an import block
# whose target is already in state is a no-op, so leaving it is harmless but
# it has served its single purpose.
#
# NOT IMPORTED — the attached inline role policies (aegis_emergency_break_glass,
# gh_tf_apply_baseline, gh_tf_plan) are Put*-idempotent: apply converges them
# onto the adopted roles without their own import blocks.
# ============================================================================

# Role name = import id for aws_iam_role. Each `to` address is confirmed present
# in this layer (aegis-emergency-role.tf / oidc-github-baseline-role.tf /
# oidc-github-plan-role.tf).

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
