# ============================================================================
# One-time adoption (prod cold-start) of the IAM roles this bootstrap layer
# manages but that survived a state clear.
#
# WHY: the prod account had its prod/bootstrap Terraform STATE cleared, but the
# three roles below still EXIST as live AWS resources (survivors — IAM roles are
# account-global and outlive the state). A prod cold-start `terraform apply`
# would otherwise fail EntityAlreadyExists when it tries to CREATE each role that
# already exists. These config-driven import blocks ADOPT the existing roles into
# state instead. After import, apply UPDATEs each role in place to match the
# declared config (a no-op if the live policy already matches) — no recreate, no
# manual `terraform import` / state surgery. Same precedent as #15
# (oidc-github-apply-deployment-role.tf in the deployment account).
#
# GATE: these survivors exist on THIS prod cold-start but NOT on a fresh account
# (a clean account creates the roles normally — no import needed, and an import
# of a non-existent role fails). So the import is TOGGLEABLE, OFF by default,
# gated on var.adopt_seeded_iam_roles via a for_each toggle: when false,
# toset([]) generates no import block; when true, each block adopts its survivor.
#
# ONE-TIME: set var.adopt_seeded_iam_roles=true only for the prod cold-start
# apply (TF_VAR_adopt_seeded_iam_roles / CI tfvar). Once prod state is
# reconciled, REMOVE this file and the variable in a later cleanup PR — an import
# block whose target is already in state is a no-op, so leaving it is harmless
# but it has served its single purpose.
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
