# -----------------------------------------------------------------------------
# `gh-tf-apply-deployment` — cross-account Terraform/ECR role for the shared
# release registry (ADR-018 / aegis-platform-aws ADR-10).
# -----------------------------------------------------------------------------
# The platform-aws CI manages the shared ECR registry that lives in THIS
# deployment account. It does so through a second AWS provider (the `aws.deployment`
# alias in aegis-platform-aws terraform/envs/platform/deployment-ecr.tf) that
# ASSUMES this role. On APPLY the platform runner is `gh-tf-apply-platform`; on
# DESTROY (infra-ops.yml destroy-platform) the runner is `gh-tf-destroy-platform`.
# BOTH must be able to assume this role or the `aws.deployment` provider cannot
# configure and the operation aborts before it touches the shared registry.
#
# WHY HERE (landing-zone deployment/bootstrap), NOT in the platform state:
#   - This role lives in the DEPLOYMENT account (162975888022). The default
#     provider of this layer already targets that account, alongside the OIDC
#     provider + the other gh-tf-* roles it seeds. Right account, right tier.
#   - It CANNOT live in aegis-platform-aws envs/platform: that state is exactly
#     what `destroy-platform` tears down, and that state ASSUMES this role to
#     configure its provider. A role cannot create the role it assumes
#     (chicken-egg), and a destroy would delete it mid-teardown (the self-delete
#     class ADR-13 eliminated for the platform CI roles).
#   - Previously the role was hand-seeded via break-glass and its trust policy
#     was patched by hand (`aws iam update-assume-role-policy`, ws3-bring-up.md
#     Phase 1b). That trust referenced ONLY gh-tf-apply-platform, so a
#     destroy-platform run assuming gh-tf-destroy-platform got AssumeRole
#     AccessDenied — the cross-account teardown gap this file closes. Making the
#     role + trust Terraform-managed is the hardening follow-up named in
#     ws3-bring-up.md Phase 1b ("make gh-tf-apply-deployment Terraform-managed
#     (landing zone) so the trust is reproducible and never dangles again").
#
# SCP: the `gh-tf-*` name falls under the org-root deny-iam-privilege-escalation
# carve-out (ADR-018), so creating it from gh-tf-apply-baseline is not SCP-denied
# and no SCP change is required.
#
# PERMISSIONS: AdministratorAccess, matching the role's seeded reality (it manages
# ECR repositories + cross-account repository/lifecycle policies + the scoped
# workload push roles in deployment-ecr.tf). Tightening to an ECR/IAM-scoped policy
# is deferred hardening, symmetric with the gh-tf-apply-platform admin attachment
# in aegis-platform-aws.
# -----------------------------------------------------------------------------

locals {
  # Platform accounts whose CI owns the shared-registry resources in THIS
  # account (deployment-ecr.tf single-owner gate). Today only STAGING carries
  # `deployment_account_id` in aegis-platform-aws/accounts.json, so only its
  # apply/destroy roles assume gh-tf-apply-deployment. Add prod's id here IF
  # registry ownership ever moves (keep it in lock-step with the
  # `deployment_account_id` field in accounts.json — both sides must agree).
  deployment_owning_platform_account_ids = [
    local.config.accounts.staging.id,
  ]

  # Both platform CI roles must assume this role: gh-tf-apply-platform on apply,
  # gh-tf-destroy-platform on destroy (infra-ops.yml destroy-platform). Omitting
  # the destroy role is the bug this file fixes — destroy could not configure the
  # `aws.deployment` provider and aborted before deleting the shared-registry
  # resources it owns.
  deployment_trusted_platform_role_arns = flatten([
    for acct in local.deployment_owning_platform_account_ids : [
      "arn:aws:iam::${acct}:role/gh-tf-apply-platform",
      "arn:aws:iam::${acct}:role/gh-tf-destroy-platform",
    ]
  ])
}

resource "aws_iam_role" "gh_tf_apply_deployment" {
  name = "gh-tf-apply-deployment"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          # Account-role principals (not the OIDC provider): the platform CI has
          # already federated into its OWN account via OIDC, then makes a plain
          # sts:AssumeRole hop into THIS account through the `aws.deployment`
          # provider's assume_role block. So the trusted principal is the
          # platform role ARN, and the action is sts:AssumeRole (not
          # AssumeRoleWithWebIdentity).
          AWS = local.deployment_trusted_platform_role_arns
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "gh_tf_apply_deployment_admin" {
  role       = aws_iam_role.gh_tf_apply_deployment.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "gh_tf_apply_deployment_role_arn" {
  description = "ARN of the cross-account Terraform/ECR role the platform CI assumes to manage the shared release registry (ADR-018)."
  value       = aws_iam_role.gh_tf_apply_deployment.arn
}
