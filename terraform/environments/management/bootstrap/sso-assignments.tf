# -----------------------------------------------------------------------------
# IAM Identity Center — per-account Permission Set assignments
# -----------------------------------------------------------------------------
# IAM Identity Center (SSO) permission sets are defined once at the Organization
# level, but must be EXPLICITLY ASSIGNED to each target account that should
# accept them. An assignment is what causes AWS to lazily create the
# corresponding `AWSReservedSSO_<PermissionSet>_<hash>` IAM role in the target
# account. Without the assignment, the role simply does not exist there.
#
# This layer assigns PlatformAdmin to the operator in the staging account so
# that (a) the operator has human admin access to the account and (b) the
# `aegis-emergency-break-glass` role in staging/bootstrap — whose trust policy
# keys on the `AWSReservedSSO_PlatformAdmin_*` role — has a principal to trust.
# Downstream consumers in the staging account rely on the same reserved role
# being present; this assignment is their account-fabric prerequisite.
# -----------------------------------------------------------------------------

# Discover the Identity Center instance (there is exactly one per organization).
data "aws_ssoadmin_instances" "main" {}

# Resolve the PlatformAdmin permission set by name. The permission set itself
# was created manually during Phase 0 (see runbook 001 section 5). This data
# source depends only on the name — if the permission set is renamed, this
# lookup breaks with a clear error.
data "aws_ssoadmin_permission_set" "platform_admin" {
  instance_arn = tolist(data.aws_ssoadmin_instances.main.arns)[0]
  name         = "PlatformAdmin"
}

# Resolve the operator user `bin` from the Identity Center directory.
data "aws_identitystore_user" "bin" {
  identity_store_id = tolist(data.aws_ssoadmin_instances.main.identity_store_ids)[0]

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = "bin"
    }
  }
}

# -----------------------------------------------------------------------------
# Staging — PlatformAdmin for operator `bin`
# -----------------------------------------------------------------------------
# Assigning PlatformAdmin to staging creates the reserved role
# `AWSReservedSSO_PlatformAdmin_<hash>` in the staging account on next SSO
# sync. The operator uses it for direct account access and break-glass
# recovery.
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# IMPORTANT (see docs/incidents.md Incident 8): before adding NEW assignment
# resources to this file, run `aws sso-admin list-account-assignments` against
# the target to confirm the assignment does not already exist from a prior
# Console click. The SSO create API is NOT idempotent over pre-existing
# assignments — it returns `ConflictException: already exists` and the
# baseline apply fails. The recovery is `terraform import` with the six-part
# assignment ID. Incident 8 has the exact ID format and recovery commands.
# -----------------------------------------------------------------------------
resource "aws_ssoadmin_account_assignment" "bin_staging_platform_admin" {
  instance_arn       = tolist(data.aws_ssoadmin_instances.main.arns)[0]
  permission_set_arn = data.aws_ssoadmin_permission_set.platform_admin.arn

  principal_id   = data.aws_identitystore_user.bin.user_id
  principal_type = "USER"

  target_id   = local.config.accounts.staging.id
  target_type = "AWS_ACCOUNT"
}

# -----------------------------------------------------------------------------
# Shared + Prod — placeholder for future expansion
# -----------------------------------------------------------------------------
# Shared and Prod assignments are intentionally commented out. They are added
# when those accounts acquire workloads that the operator must reach directly.
# Prod in particular should stay assignment-free until ADR-011 Path A account
# promotion for prod is complete and a production workload exists.
#
# resource "aws_ssoadmin_account_assignment" "bin_prod_platform_admin" {
#   instance_arn       = tolist(data.aws_ssoadmin_instances.main.arns)[0]
#   permission_set_arn = data.aws_ssoadmin_permission_set.platform_admin.arn
#   principal_id       = data.aws_identitystore_user.bin.user_id
#   principal_type     = "USER"
#   target_id          = local.config.accounts.prod.id
#   target_type        = "AWS_ACCOUNT"
# }
